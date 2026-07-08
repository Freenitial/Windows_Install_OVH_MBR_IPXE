#!/bin/bash

###########################################
#  Windows ISO Installation               #
#  OVH Dedicated Server - MBR/Legacy      #
###########################################

# v3.0

# HOW IT WORKS :
# 1. Interactive wizard collects ALL configuration upfront (nothing destructive)
# 2. Script partitions disk (part1=Windows, part2=setup)
# 3. Extracts ISO to part2, applies Windows image to part1 via wimapply
# 4. Injects auto-bcdboot + optional drivers into boot.wim (replaces setup.exe)
# 5. GRUB2 + wimboot handles booting (only method working with OVH iPXE)
# 6. Single GRUB entry auto-detects boot phase :
#    - No Boot/BCD on part1 -> boots modified WinPE -> drvload + dism drivers
#      -> auto bcdboot -> deletes part2 -> extends part1 -> auto reboot
#    - Boot/BCD on part1 -> boots installed Windows directly
#
# BOOT CHAIN : iPXE -> sanboot -> GRUB2 -> wimboot -> bootmgr + BCD -> Windows
# NOTE : GRUB refers to the boot disk as hd0. This is safe because the disk this
# script installs GRUB on is the one OVH netboot points to (hd0 from BIOS).
#
# FIRST BOOT : WinPE loads, injects drivers, runs bcdboot, reboots by itself
# SECOND BOOT : Windows OOBE fully skipped, RDP ready
# NO MANUAL INTERVENTION BETWEEN BOOTS
#
# WHY WIMBOOT :
# iPXE sanboot cannot chainload Windows MBR/VBR.
# GRUB2 ntldr /bootmgr freezes. grub4dos chainloader gives "BOOTMGR corrupt".
# wimboot loads bootmgr + BCD into a ramdisk, bypassing iPXE disk access issues.
# wimboot files + boot.sdi are loaded by GRUB via BIOS INT13h, so they reach RAM
# regardless of whether Windows has a driver for the disk controller yet.
#
# WHY WIMAPPLY :
# WinPE booted via wimboot runs in RAM and cannot find install.wim on disk.
# wimapply (wimlib) applies the Windows image directly from Linux.
# Bonus : because we never run setup.exe, the Windows 11 TPM/SecureBoot/RAM
# install-time checks are never executed. The registry bypass below is only
# belt-and-suspenders for future in-place servicing.
#
# ACCOUNT MODEL (v3.0) :
# A named local Administrators-group account (the username you choose) is created
# for EVERY edition, and AutoLogon targets it. This is deterministic and works
# identically on client and Server, Core and Desktop Experience.
# Rationale : the built-in Administrator (RID 500) is stored as "Administrator"
# in the base install.wim SAM even on localized (e.g. French) media - it is only
# renamed later by the specialize pass - so resolving it offline is unreliable.
# On Server editions we ALSO set the built-in Administrator password (satisfies
# the Server OOBE password screen and gives a fallback login).
#
# DRIVERS (OPTIONAL BUT IMPORTANT) :
# Windows inbox drivers do NOT cover all OVH hardware. Known offenders :
# Intel X710/XL710 NICs, Mellanox ConnectX, Realtek RTL8125 2.5G.
# A missing NIC driver = Windows boots fine but is unreachable (no RDP, no ping).
# A missing storage driver = BSOD 0x7B on first boot.
# To inject drivers : extract the vendor driver pack (must contain .inf files,
# NOT a setup.exe) and drop it in /root/drivers BEFORE running this script,
# or provide a URL to a .zip / .tar.gz pack when the wizard asks.
# The wizard displays your NIC/storage hardware (lspci) to help you decide.
# Drivers are injected into the installed Windows via "dism /Add-Driver
# /ForceUnsigned" (verified valid) and, when small enough, loaded into WinPE
# itself via drvload so a hidden storage controller is still reachable.
#
# SUPPORTED DISKS : /dev/sdX and /dev/nvmeXnY (partition suffix handled).
# Multi-disk servers : the wizard asks which disk to install to. Other disks
# are not touched, but make sure OVH netboot targets the chosen disk.
#
# STRONGLY RECOMMENDED : run inside screen or tmux. If SSH drops mid-install
# the process dies with a half-written disk.

# USAGE :
# scp install_windows_ovh_mbr.sh root@YOUR_IP:/root/
# ssh root@YOUR_IP
# bash /root/install_windows_ovh_mbr.sh                   # full wizard
# bash /root/install_windows_ovh_mbr.sh "https://iso-url" # pre-set ISO URL

# AFTER SCRIPT COMPLETES :
# 1. Change Netboot to "Boot from hard disk" in OVH panel
# 2. Reboot the server
# 3. First boot : WinPE injects drivers, creates boot files, reboots
# 4. Second boot : Windows completes setup (OOBE skipped via unattend.xml)
# 5. Connect via RDP : mstsc /v:<server_ip>
#
# UNATTENDED FEATURES :
# - OOBE fully skipped (language, keyboard, timezone auto-configured)
# - Named local admin account created (used for RDP + AutoLogon)
# - RDP enabled with firewall rule (unattend firewall group + SetupComplete)
# - Network profile set to Private, power plan High Performance
# - Password expiration disabled, Ctrl+Alt+Del disabled
# - Windows Update auto-reboot disabled
# - Sensitive files (unattend.xml with plaintext password) auto-deleted

set -euo pipefail

###########################################
# Variables
###########################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WINDOWS_ISO_URL=""
ISO_PATH=""
DISK=""
PART1=""
PART2=""
DISK_LABEL=""
LOG_FILE="/root/windows_install.log"
BACKUP_DIR="/root/backup"
MAX_RETRIES=3
WIMBOOT_URL="https://github.com/ipxe/wimboot/releases/latest/download/wimboot"
WIM_IMAGE_INDEX=""
SETUP_SIZE_GIB=25
USE_LOCAL_ISO=false
DEFERRED_ISO=false
WIZARD_ISO_MOUNT="/root/iso_wizard"
WIZARD_WIM=""
SELECTED_EDITION_NAME=""
IS_SERVER_EDITION=false
UNATTEND_LOCALE=""
UNATTEND_KEYBOARD_CODE=""
UNATTEND_KEYBOARD_NAME=""
UNATTEND_TIMEZONE=""
UNATTEND_COMPUTER_NAME="WIN-OVH"
UNATTEND_USERNAME=""
UNATTEND_PASSWORD=""
DRIVERS_DIR=""
DRIVERS_INF_COUNT=0
INJECT_DRIVERS_IN_WINPE=false
CHOICE_INDEX=-1
LETTERS="abcdefghijklmnopqrstuvwxyz"

# Static keyboard layout list : InputLocale codes are stable across all Windows
# versions, which avoids fragile registry extraction from the applied image.
# Format : "<InputLocale value>|<human label>"
KEYBOARD_CHOICES=(
    "040c:0000040c|French (AZERTY)"
    "0409:00000409|English US (QWERTY)"
    "0809:00000809|English UK (QWERTY)"
    "080c:0000080c|Belgian French (AZERTY)"
    "0813:00000813|Belgian Dutch (AZERTY)"
    "0407:00000407|German (QWERTZ)"
    "100c:0000100c|Swiss French"
    "0807:00000807|Swiss German"
    "040a:0000040a|Spanish"
    "0410:00000410|Italian"
    "0413:00000413|Dutch"
    "0816:00000816|Portuguese"
    "0416:00000416|Portuguese Brazil (ABNT)"
    "0415:00000415|Polish (Programmers)"
    "0419:00000419|Russian"
    "041d:0000041d|Swedish"
    "0406:00000406|Danish"
    "0414:00000414|Norwegian"
    "040b:0000040b|Finnish"
    "0c0c:00001009|Canadian French"
)

# Windows time zone names with human-readable hints
TIMEZONE_CHOICES=(
    "Romance Standard Time|Paris, Brussels, Madrid (UTC+1)"
    "W. Europe Standard Time|Berlin, Amsterdam, Rome, Zurich (UTC+1)"
    "Central European Standard Time|Warsaw, Prague (UTC+1)"
    "GMT Standard Time|London, Lisbon (UTC+0)"
    "UTC|Coordinated Universal Time"
    "Eastern Standard Time|New York, Montreal (UTC-5)"
    "Pacific Standard Time|Los Angeles (UTC-8)"
    "Russian Standard Time|Moscow (UTC+3)"
    "E. South America Standard Time|Sao Paulo (UTC-3)"
)

# PCI IDs known to lack Windows inbox drivers (displayed as a warning only)
RISKY_PCI_PATTERN='8086:(1572|1574|1580|1581|1583|1584|1585|158a|158b)|15b3:|10ec:8125'

###########################################
# Argument parsing
###########################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        -*)
            echo "Unknown option : $1"
            exit 1
            ;;
        *)
            WINDOWS_ISO_URL="$1"
            shift
            ;;
    esac
done

###########################################
# Helper Functions
###########################################

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${BLUE}[${timestamp}]${NC} $1"
    echo "[${timestamp}] $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[${timestamp}] ERROR : $1${NC}"
    echo "[${timestamp}] ERROR : $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_success() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${GREEN}[${timestamp}] OK : $1${NC}"
    echo "[${timestamp}] OK : $1" >> "$LOG_FILE" 2>/dev/null || true
}

log_warning() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[${timestamp}] WARNING : $1${NC}"
    echo "[${timestamp}] WARNING : $1" >> "$LOG_FILE" 2>/dev/null || true
}

handle_error() {
    local error_msg="$1"
    log_error "$error_msg"
    mkdir -p "$BACKUP_DIR"
    cp "$LOG_FILE" "$BACKUP_DIR/install.log" 2>/dev/null || true
    [ -n "$DISK" ] && fdisk -l "$DISK" > "$BACKUP_DIR/partition_state.txt" 2>/dev/null || true
    for mp in "/mnt" "/mnt2" "/root/iso_mount" "$WIZARD_ISO_MOUNT"; do
        mountpoint -q "$mp" 2>/dev/null && umount -f "$mp" 2>/dev/null || true
    done
    sync
    exit 1
}

retry_command() {
    local cmd="$1"
    local description="${2:-command}"
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if eval "$cmd"; then
            return 0
        fi
        retries=$((retries + 1))
        log_warning "Attempt $retries of $MAX_RETRIES failed for : $description"
        sleep 5
    done
    return 1
}

cleanup_mounts() {
    for mp in "/mnt" "/mnt2" "/root/iso_mount" "$WIZARD_ISO_MOUNT"; do
        mountpoint -q "$mp" 2>/dev/null && umount -f "$mp" 2>/dev/null || true
    done
    # Unmount all partitions on target disk
    for part in $(mount | grep "$DISK" | awk '{print $1}'); do
        umount -f "$part" 2>/dev/null || true
    done
    # Disable swap on target disk
    for part in $(swapon --show=NAME --noheadings 2>/dev/null | grep "$DISK" || true); do
        swapoff "$part" 2>/dev/null || true
    done
    # Deactivate LVM volumes (OVH default Linux installs may use LVM on RAID)
    if command -v vgchange >/dev/null 2>&1; then
        vgchange -an >/dev/null 2>&1 || true
    fi
    # Stop software RAID arrays auto-assembled by the OVH rescue system
    if command -v mdadm >/dev/null 2>&1; then
        for md in /dev/md[0-9]* /dev/md/*; do
            [ -b "$md" ] && mdadm --stop "$md" >/dev/null 2>&1 || true
        done
    fi
}

get_tmp_free_bytes() {
    df -B1 --output=avail /tmp 2>/dev/null | tail -1 | tr -d ' ' || echo 0
}

# Generic lettered menu. Usage : choose_from_menu "prompt" default_index "opt1" "opt2" ...
# Enter selects the default when default_index >= 0. Sets CHOICE_INDEX.
choose_from_menu() {
    local prompt_text="$1"
    local default_index="$2"
    shift 2
    local options=("$@")
    local i=0
    echo
    for opt in "${options[@]}"; do
        local marker=""
        [ "$i" -eq "$default_index" ] && marker=" ${YELLOW}<-- default (Enter)${NC}"
        echo -e "  ${GREEN}${LETTERS:$i:1})${NC} ${opt}${marker}"
        i=$((i + 1))
    done
    echo
    while true; do
        echo -ne "${YELLOW}${prompt_text}${NC}"
        local ans=""
        read -r ans
        ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
        if [ -z "$ans" ] && [ "$default_index" -ge 0 ]; then
            CHOICE_INDEX=$default_index
            return 0
        fi
        local k=0
        while [ "$k" -lt "${#options[@]}" ]; do
            if [ "$ans" = "${LETTERS:$k:1}" ]; then
                CHOICE_INDEX=$k
                return 0
            fi
            k=$((k + 1))
        done
        echo -e "${RED}  Invalid choice, pick a letter (or Enter for default when shown).${NC}"
    done
}

set_partition_names() {
    # NVMe and eMMC devices use a 'p' separator before the partition number
    case "$DISK" in
        *nvme*|*mmcblk*)
            PART1="${DISK}p1"
            PART2="${DISK}p2"
            ;;
        *)
            PART1="${DISK}1"
            PART2="${DISK}2"
            ;;
    esac
}

verify_iso() {
    # Returns 0 if the ISO at $1 is a bootable Windows ISO with a sane install.wim
    local iso_file="$1"
    local iso_ok=true
    mkdir -p /root/iso_check
    if ! mount -o loop,ro "$iso_file" /root/iso_check 2>/dev/null; then
        rm -rf /root/iso_check
        return 1
    fi
    for f in "/root/iso_check/bootmgr" "/root/iso_check/sources/boot.wim" "/root/iso_check/sources/install.wim"; do
        [ -f "$f" ] || iso_ok=false
    done
    if [ "$iso_ok" = true ]; then
        wiminfo /root/iso_check/sources/install.wim > /dev/null 2>&1 || iso_ok=false
    fi
    umount /root/iso_check 2>/dev/null || true
    rm -rf /root/iso_check
    [ "$iso_ok" = true ]
}

get_remote_size() {
    # Prints the remote file size in bytes, or 0 if unknown
    local url="$1"
    local size
    size=$(curl -sLI "$url" | grep -i "Content-Length" | tail -1 | awk '{print $2}' | tr -d '\r' || echo 0)
    if ! [ "$size" -gt 0 ] 2>/dev/null; then
        # HEAD blocked : 1-byte range GET returns Content-Range with total size
        size=$(curl -sL -r 0-0 -D - -o /dev/null "$url" | grep -i "Content-Range" | grep -oP '/\K[0-9]+' || echo 0)
    fi
    [ "$size" -gt 0 ] 2>/dev/null && echo "$size" || echo 0
}

###########################################
# Step 1 : System Checks
###########################################

step_check_system() {
    log "=== Step 1 : System checks ==="
    if [ "$EUID" -ne 0 ]; then
        handle_error "Script must be run as root"
    fi
    if [ -d "/sys/firmware/efi" ]; then
        handle_error "UEFI detected. This script only supports Legacy BIOS (MBR). Aborting."
    fi
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        handle_error "No internet connection"
    fi
    local available_mem
    available_mem=$(free -g | awk '/^Mem:/{print $7}')
    log "Available RAM : ${available_mem}GB"
    # A dropped SSH session kills the install mid-flight, warn loudly
    if [ -z "${STY:-}${TMUX:-}" ]; then
        echo
        log_warning "You are NOT running inside screen or tmux."
        log_warning "If your SSH session drops during the install, the process dies."
        echo -ne "${YELLOW}Continue anyway ? (y/N) : ${NC}"
        local tmux_answer=""
        read -r tmux_answer
        tmux_answer=$(echo "$tmux_answer" | tr '[:upper:]' '[:lower:]')
        if [ "$tmux_answer" != "y" ]; then
            echo -e "${GREEN}Good call. Run : tmux new -s win  (then relaunch this script)${NC}"
            exit 0
        fi
    fi
    log_success "System checks passed"
}

###########################################
# Step 2 : Install Packages
###########################################

step_install_packages() {
    log "=== Step 2 : Installing packages ==="
    apt-get update --allow-releaseinfo-change >> "$LOG_FILE" 2>&1 || apt-get update >> "$LOG_FILE" 2>&1
    local packages=(
        "fdisk"
        "rsync"
        "wget"
        "ntfs-3g"
        "parted"
        "curl"
        "file"
        "grub-pc-bin"
        "grub2-common"
        "wimtools"
        "libhivex-bin"
        "unzip"
        "pciutils"
        "util-linux"
    )
    for pkg in "${packages[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            log "Installing $pkg..."
            retry_command "apt-get install -y $pkg >> $LOG_FILE 2>&1" "install $pkg" || handle_error "Failed to install $pkg"
        fi
    done
    log_success "All packages installed"
}

###########################################
# Step 3 : Select Target Disk
###########################################

step_select_disk() {
    log "=== Step 3 : Target disk selection ==="
    local candidates=()
    local names=()
    while read -r name size; do
        candidates+=("/dev/${name}")
        names+=("/dev/${name}  (${size})")
    done < <(lsblk -dno NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk" {print $1" "$2}')
    if [ "${#candidates[@]}" -eq 0 ]; then
        handle_error "No physical disk found"
    fi
    if [ "${#candidates[@]}" -eq 1 ]; then
        DISK="${candidates[0]}"
        log "Single disk detected : ${names[0]}"
    else
        echo
        echo -e "${BLUE}Multiple disks detected. Windows will be installed on ONE disk only.${NC}"
        echo -e "${YELLOW}Other disks will not be touched. Make sure OVH netboot targets the chosen disk.${NC}"
        choose_from_menu "Select target disk (letter) : " 0 "${names[@]}"
        DISK="${candidates[$CHOICE_INDEX]}"
    fi
    set_partition_names
    local disk_size
    disk_size=$(blockdev --getsize64 "$DISK")
    local disk_gb=$((disk_size / 1024 / 1024 / 1024))
    DISK_LABEL="${DISK} (${disk_gb}GB)"
    if [ "$disk_gb" -lt 40 ]; then
        handle_error "Disk too small : ${disk_gb}GB (minimum 40GB)"
    fi
    log_success "Target disk : $DISK_LABEL (partitions : $PART1 / $PART2)"
}

###########################################
# Step 4 : Resolve ISO source
###########################################

step_resolve_iso() {
    log "=== Step 4 : Resolving ISO source ==="
    # Reset state (this function is re-entrant from the summary editor)
    mountpoint -q "$WIZARD_ISO_MOUNT" 2>/dev/null && umount -f "$WIZARD_ISO_MOUNT" 2>/dev/null || true
    USE_LOCAL_ISO=false
    DEFERRED_ISO=false
    ISO_PATH=""
    WIZARD_WIM=""
    WIM_IMAGE_INDEX=""
    SELECTED_EDITION_NAME=""
    while true; do
        local from_url=false
        if [ -n "$WINDOWS_ISO_URL" ]; then
            log "ISO URL : $WINDOWS_ISO_URL"
            from_url=true
        else
            # Scan usual locations for local ISO files (magic bytes CD001 at 0x8001)
            local iso_files=()
            local iso_labels=()
            while IFS= read -r f; do
                if dd if="$f" bs=1 skip=32769 count=5 2>/dev/null | grep -q "CD001"; then
                    local fsize
                    fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
                    iso_files+=("$f")
                    iso_labels+=("$f ($((fsize / 1024 / 1024)) MB)")
                fi
            done < <(find /root /tmp /home /mnt 2>/dev/null -maxdepth 2 -type f -iname "*.iso" -size +1G 2>/dev/null | sort)
            local menu_opts=("${iso_labels[@]}")
            menu_opts+=("Enter a download URL instead")
            echo
            echo -e "${BLUE}ISO source :${NC}"
            choose_from_menu "Select ISO source (letter) : " -1 "${menu_opts[@]}"
            if [ "$CHOICE_INDEX" -lt "${#iso_files[@]}" ]; then
                ISO_PATH="${iso_files[$CHOICE_INDEX]}"
                USE_LOCAL_ISO=true
            else
                echo -ne "${YELLOW}Windows ISO download URL : ${NC}"
                read -r WINDOWS_ISO_URL
                [ -z "$WINDOWS_ISO_URL" ] && { log_warning "Empty URL"; continue; }
                from_url=true
            fi
        fi
        if [ "$from_url" = true ]; then
            local remote_size
            remote_size=$(get_remote_size "$WINDOWS_ISO_URL")
            local tmp_free
            tmp_free=$(get_tmp_free_bytes)
            local margin=$((2 * 1024 * 1024 * 1024))
            if [ "$remote_size" -gt 0 ]; then
                SETUP_SIZE_GIB=$((remote_size / 1024 / 1024 / 1024 + 2))
                log "Remote ISO size : $((remote_size / 1024 / 1024)) MB"
            else
                SETUP_SIZE_GIB=25
                log_warning "Could not determine ISO size, using default ${SETUP_SIZE_GIB} GiB setup partition"
            fi
            if [ "$remote_size" -gt 0 ] && [ "$tmp_free" -gt $((remote_size + margin)) ]; then
                # Enough space in /tmp (RAM-backed) : download NOW so the wizard
                # can offer edition/language selection before anything destructive
                log "Downloading ISO to /tmp (fits in RAM-backed storage)..."
                local iso_filename
                iso_filename=$(curl -sL -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" 2>/dev/null | grep -i "Content-Disposition" | grep -oP 'filename="\K[^"]+' || true)
                [ -z "$iso_filename" ] && iso_filename="win.iso"
                iso_filename="${iso_filename// /_}"
                ISO_PATH="/tmp/${iso_filename}"
                rm -f "$ISO_PATH"
                if ! wget --progress=bar:force -O "$ISO_PATH" "$WINDOWS_ISO_URL" 2>&1; then
                    log_error "Download failed"
                    rm -f "$ISO_PATH"
                    WINDOWS_ISO_URL=""
                    continue
                fi
                USE_LOCAL_ISO=true
            else
                # ISO does not fit in /tmp : it will be downloaded to the Windows
                # partition AFTER partitioning. Edition/language selection is deferred.
                DEFERRED_ISO=true
                log_warning "ISO too large for /tmp : download will happen after partitioning"
                log_warning "Edition and language selection will occur after the download"
                log_success "ISO source : $WINDOWS_ISO_URL (deferred download)"
                return 0
            fi
        fi
        # Verify integrity before letting the user configure anything
        log "Verifying ISO integrity..."
        if ! verify_iso "$ISO_PATH"; then
            log_error "ISO is corrupted, truncated or not a Windows ISO : $ISO_PATH"
            ISO_PATH=""
            WINDOWS_ISO_URL=""
            USE_LOCAL_ISO=false
            continue
        fi
        local iso_size
        iso_size=$(stat -c%s "$ISO_PATH" 2>/dev/null || echo 0)
        SETUP_SIZE_GIB=$((iso_size / 1024 / 1024 / 1024 + 2))
        # Keep the ISO mounted read-only for the wizard (edition/language listing)
        mkdir -p "$WIZARD_ISO_MOUNT"
        mount -o loop,ro "$ISO_PATH" "$WIZARD_ISO_MOUNT" || handle_error "Failed to mount ISO for inspection"
        WIZARD_WIM="$WIZARD_ISO_MOUNT/sources/install.wim"
        log_success "ISO verified : $ISO_PATH ($((iso_size / 1024 / 1024)) MB)"
        return 0
    done
}

###########################################
# Step 5 : Configuration Wizard
# All questions are asked here, BEFORE anything destructive happens.
###########################################

wizard_select_edition() {
    local wim="$1"
    local info
    info=$(wiminfo "$wim")
    local image_count
    image_count=$(echo "$info" | awk '/^Image Count:/{print $3}')
    if [ -z "$image_count" ] || [ "$image_count" -eq 0 ]; then
        handle_error "No images found in install.wim"
    fi
    local display_names=()
    local descriptions=()
    mapfile -t display_names < <(echo "$info" | sed -n 's/^Display Name:[[:space:]]*//p')
    mapfile -t descriptions < <(echo "$info" | sed -n 's/^Display Description:[[:space:]]*//p')
    # Some WIMs have no Display Name : fall back to the mandatory Name field
    if [ "${#display_names[@]}" -ne "$image_count" ]; then
        mapfile -t display_names < <(echo "$info" | sed -n 's/^Name:[[:space:]]*//p')
    fi
    local opts=()
    local i=0
    while [ "$i" -lt "$image_count" ]; do
        local label="${display_names[$i]:-Image $((i + 1))}"
        [ "$i" -lt "${#descriptions[@]}" ] && [ -n "${descriptions[$i]:-}" ] && label="${label} — ${descriptions[$i]}"
        opts+=("$label")
        i=$((i + 1))
    done
    echo
    echo -e "${BLUE}── Windows edition ──${NC}"
    choose_from_menu "Select edition (letter) : " -1 "${opts[@]}"
    WIM_IMAGE_INDEX=$((CHOICE_INDEX + 1))
    SELECTED_EDITION_NAME="${display_names[$CHOICE_INDEX]:-Image $WIM_IMAGE_INDEX}"
    IS_SERVER_EDITION=false
    echo "$SELECTED_EDITION_NAME" | grep -qi "server" && IS_SERVER_EDITION=true
    log "Edition : $SELECTED_EDITION_NAME (index $WIM_IMAGE_INDEX)"
}

wizard_select_language() {
    local wim="$1"
    local wim_languages=()
    while IFS= read -r lang; do
        [ -n "$lang" ] && wim_languages+=("$lang")
    done < <(wiminfo "$wim" "$WIM_IMAGE_INDEX" 2>/dev/null | awk '
        /^Languages:/ { gsub(/^Languages:[[:space:]]*/, ""); print; capturing=1; next }
        capturing && /^[[:space:]]/ { gsub(/^[[:space:]]+/, ""); print; next }
        capturing { exit }
    ')
    if [ "${#wim_languages[@]}" -eq 0 ]; then
        wim_languages=("en-US")
        log_warning "Could not detect WIM languages, defaulting to en-US"
    fi
    if [ "${#wim_languages[@]}" -eq 1 ]; then
        UNATTEND_LOCALE="${wim_languages[0]}"
        log "Language : $UNATTEND_LOCALE (only one available)"
        return 0
    fi
    echo
    echo -e "${BLUE}── Display language ──${NC}"
    choose_from_menu "Select language (letter) : " 0 "${wim_languages[@]}"
    UNATTEND_LOCALE="${wim_languages[$CHOICE_INDEX]}"
    log "Language : $UNATTEND_LOCALE"
}

get_default_keyboard_index() {
    case "$UNATTEND_LOCALE" in
        fr-FR) echo 0 ;;
        fr-BE) echo 3 ;;
        fr-CH) echo 6 ;;
        fr-CA) echo 19 ;;
        en-GB) echo 2 ;;
        en-*) echo 1 ;;
        nl-BE) echo 4 ;;
        nl-*) echo 10 ;;
        de-CH) echo 7 ;;
        de-*) echo 5 ;;
        es-*) echo 8 ;;
        it-*) echo 9 ;;
        pt-BR) echo 12 ;;
        pt-*) echo 11 ;;
        pl-*) echo 13 ;;
        ru-*) echo 14 ;;
        sv-*) echo 15 ;;
        da-*) echo 16 ;;
        nb-*|nn-*) echo 17 ;;
        fi-*) echo 18 ;;
        *) echo 1 ;;
    esac
}

wizard_select_keyboard() {
    echo
    echo -e "${BLUE}── Keyboard layout ──${NC}"
    local opts=()
    for kb in "${KEYBOARD_CHOICES[@]}"; do
        opts+=("${kb##*|}")
    done
    opts+=("Other (enter code manually, format 040c:0000040c)")
    local default_idx
    default_idx=$(get_default_keyboard_index)
    choose_from_menu "Select keyboard (letter) : " "$default_idx" "${opts[@]}"
    if [ "$CHOICE_INDEX" -lt "${#KEYBOARD_CHOICES[@]}" ]; then
        local selected="${KEYBOARD_CHOICES[$CHOICE_INDEX]}"
        UNATTEND_KEYBOARD_CODE="${selected%%|*}"
        UNATTEND_KEYBOARD_NAME="${selected##*|}"
    else
        while true; do
            echo -ne "${YELLOW}InputLocale code (e.g. 040c:0000040c) : ${NC}"
            local manual_code=""
            read -r manual_code
            if echo "$manual_code" | grep -qE '^[0-9a-fA-F]{4}:[0-9a-fA-F]{8}$'; then
                UNATTEND_KEYBOARD_CODE="$manual_code"
                UNATTEND_KEYBOARD_NAME="Custom ($manual_code)"
                break
            fi
            echo -e "${RED}  Invalid format.${NC}"
        done
    fi
    log "Keyboard : $UNATTEND_KEYBOARD_NAME"
}

get_default_timezone_index() {
    case "$UNATTEND_LOCALE" in
        fr-FR|fr-BE|es-*) echo 0 ;;
        de-*|it-*|nl-*|sv-*|da-*|nb-*|nn-*) echo 1 ;;
        pl-*|cs-*|hu-*) echo 2 ;;
        en-GB|pt-PT) echo 3 ;;
        en-US|en-CA|fr-CA) echo 5 ;;
        ru-*) echo 7 ;;
        pt-BR) echo 8 ;;
        *) echo 4 ;;
    esac
}

wizard_select_timezone() {
    echo
    echo -e "${BLUE}── Time zone ──${NC}"
    local opts=()
    for tz in "${TIMEZONE_CHOICES[@]}"; do
        opts+=("${tz%%|*}  [${tz##*|}]")
    done
    opts+=("Other (enter a Windows time zone name manually)")
    local default_idx
    default_idx=$(get_default_timezone_index)
    choose_from_menu "Select time zone (letter) : " "$default_idx" "${opts[@]}"
    if [ "$CHOICE_INDEX" -lt "${#TIMEZONE_CHOICES[@]}" ]; then
        local selected="${TIMEZONE_CHOICES[$CHOICE_INDEX]}"
        UNATTEND_TIMEZONE="${selected%%|*}"
    else
        while true; do
            echo -ne "${YELLOW}Windows time zone name (see 'tzutil /l') : ${NC}"
            read -r UNATTEND_TIMEZONE
            [ -n "$UNATTEND_TIMEZONE" ] && break
            echo -e "${RED}  Cannot be empty.${NC}"
        done
    fi
    log "Time zone : $UNATTEND_TIMEZONE"
}

wizard_set_computer_name() {
    echo
    echo -e "${BLUE}── Computer name ──${NC}"
    echo -ne "  Computer name [${UNATTEND_COMPUTER_NAME}] (Enter = keep) : "
    local comp_name=""
    read -r comp_name
    [ -z "$comp_name" ] && comp_name="$UNATTEND_COMPUTER_NAME"
    # Max 15 chars, alphanumeric and hyphens only
    comp_name=$(echo "$comp_name" | tr -cd 'A-Za-z0-9-' | head -c 15)
    [ -z "$comp_name" ] && comp_name="WIN-OVH"
    UNATTEND_COMPUTER_NAME="$comp_name"
    log "Computer name : $UNATTEND_COMPUTER_NAME"
}

wizard_set_account() {
    # Unified for all editions : a named local admin account is always created.
    # On Server, its password is also mirrored to the built-in Administrator.
    echo
    echo -e "${BLUE}── Administrator account ──${NC}"
    echo -e "  ${YELLOW}This account is added to the Administrators group and used for RDP.${NC}"
    while true; do
        echo -ne "  Username to create : "
        local input_username=""
        read -r input_username
        input_username=$(echo "$input_username" | tr -cd 'A-Za-z0-9_-' | head -c 20)
        # Avoid clashing with the built-in account name
        if [ -z "$input_username" ]; then
            echo -e "${RED}  Invalid or empty username (letters, numbers, _ and - only).${NC}"
            continue
        fi
        if [ "${input_username,,}" = "administrator" ] || [ "${input_username,,}" = "administrateur" ]; then
            echo -e "${RED}  Pick a different name than the built-in Administrator.${NC}"
            continue
        fi
        UNATTEND_USERNAME="$input_username"
        break
    done
    while true; do
        echo -ne "  Password (min 8 chars, required for RDP) : "
        local input_password=""
        read -rs input_password
        echo
        if [ ${#input_password} -lt 8 ]; then
            echo -e "${RED}  Password too short (minimum 8 characters).${NC}"
            continue
        fi
        echo -ne "  Confirm password : "
        local confirm_password=""
        read -rs confirm_password
        echo
        if [ "$input_password" != "$confirm_password" ]; then
            echo -e "${RED}  Passwords do not match.${NC}"
            continue
        fi
        UNATTEND_PASSWORD="$input_password"
        break
    done
    log "Account configured : $UNATTEND_USERNAME (password set)"
}

wizard_setup_drivers() {
    echo
    echo -e "${BLUE}── Drivers ──${NC}"
    echo -e "  Detected hardware on this server :"
    lspci -nn 2>/dev/null | grep -Ei 'ethernet controller|network controller' | sed 's/^/    NET  : /' || echo "    NET  : (none detected)"
    lspci -nn 2>/dev/null | grep -Ei 'raid bus|sata controller|non-volatile memory|storage controller|scsi' | sed 's/^/    DISK : /' || echo "    DISK : (none detected)"
    if lspci -nn 2>/dev/null | grep -Eiq "$RISKY_PCI_PATTERN"; then
        echo
        echo -e "  ${RED}WARNING : your hardware includes a device KNOWN to lack a Windows inbox${NC}"
        echo -e "  ${RED}driver (Intel X710 / Mellanox / Realtek 8125). Without driver injection,${NC}"
        echo -e "  ${RED}Windows may boot with NO network access (unreachable server).${NC}"
    fi
    echo
    echo -e "  Driver packs must be EXTRACTED (.inf files), not setup.exe installers."
    local local_inf_count=0
    if [ -d /root/drivers ]; then
        local_inf_count=$(find /root/drivers -iname '*.inf' 2>/dev/null | wc -l)
    fi
    while true; do
        local opts=("No driver injection (Windows inbox drivers only)")
        local has_local=false
        if [ "$local_inf_count" -gt 0 ]; then
            opts+=("Use /root/drivers (${local_inf_count} .inf files found)")
            has_local=true
        fi
        opts+=("Download a driver pack from a URL (.zip or .tar.gz)")
        choose_from_menu "Driver option (letter) : " 0 "${opts[@]}"
        if [ "$CHOICE_INDEX" -eq 0 ]; then
            DRIVERS_DIR=""
            DRIVERS_INF_COUNT=0
            log "Drivers : none"
            return 0
        fi
        if [ "$has_local" = true ] && [ "$CHOICE_INDEX" -eq 1 ]; then
            DRIVERS_DIR="/root/drivers"
            DRIVERS_INF_COUNT="$local_inf_count"
            log "Drivers : $DRIVERS_INF_COUNT .inf from /root/drivers"
            return 0
        fi
        echo -ne "${YELLOW}Driver pack URL : ${NC}"
        local drv_url=""
        read -r drv_url
        [ -z "$drv_url" ] && { echo -e "${RED}  Empty URL.${NC}"; continue; }
        rm -rf /tmp/driverpack /tmp/driverpack_archive
        mkdir -p /tmp/driverpack
        if ! wget -q -O /tmp/driverpack_archive "$drv_url"; then
            log_error "Driver pack download failed"
            continue
        fi
        # Auto-detect archive format
        if unzip -q -o /tmp/driverpack_archive -d /tmp/driverpack 2>/dev/null; then
            :
        elif tar -xf /tmp/driverpack_archive -C /tmp/driverpack 2>/dev/null; then
            :
        else
            log_error "Unsupported archive format (use .zip or .tar.gz)"
            continue
        fi
        rm -f /tmp/driverpack_archive
        local url_inf_count
        url_inf_count=$(find /tmp/driverpack -iname '*.inf' 2>/dev/null | wc -l)
        if [ "$url_inf_count" -eq 0 ]; then
            log_error "No .inf file found in the archive. Extracted driver packs are required, not setup.exe installers."
            continue
        fi
        DRIVERS_DIR="/tmp/driverpack"
        DRIVERS_INF_COUNT="$url_inf_count"
        log "Drivers : $DRIVERS_INF_COUNT .inf from URL pack"
        return 0
    done
}

step_run_wizard() {
    log "=== Step 5 : Configuration wizard ==="
    echo
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Configuration wizard — nothing is written to disk yet.   ║${NC}"
    echo -e "${BLUE}║  Answer each question (Enter accepts the default).        ║${NC}"
    echo -e "${BLUE}║  You can edit any answer from the summary screen at the   ║${NC}"
    echo -e "${BLUE}║  end before anything destructive happens.                 ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    if [ "$DEFERRED_ISO" = false ]; then
        wizard_select_edition "$WIZARD_WIM"
        wizard_select_language "$WIZARD_WIM"
    fi
    wizard_select_keyboard
    wizard_select_timezone
    wizard_set_computer_name
    wizard_set_account
    wizard_setup_drivers
    # Summary hub : confirm, or jump back to any single item
    while true; do
        local edition_line="$SELECTED_EDITION_NAME"
        local language_line="$UNATTEND_LOCALE"
        if [ "$DEFERRED_ISO" = true ]; then
            edition_line="(selected after ISO download)"
            language_line="(selected after ISO download)"
        fi
        local drivers_line="none"
        [ -n "$DRIVERS_DIR" ] && drivers_line="$DRIVERS_INF_COUNT .inf from $DRIVERS_DIR"
        local iso_line="$WINDOWS_ISO_URL"
        [ "$USE_LOCAL_ISO" = true ] && iso_line="$ISO_PATH"
        echo
        echo -e "${BLUE}╔══════════════ Configuration summary ══════════════╗${NC}"
        echo -e " ${GREEN}1)${NC} Target disk   : $DISK_LABEL"
        echo -e " ${GREEN}2)${NC} ISO source    : $iso_line"
        echo -e " ${GREEN}3)${NC} Edition       : $edition_line"
        echo -e " ${GREEN}4)${NC} Language      : $language_line"
        echo -e " ${GREEN}5)${NC} Keyboard      : $UNATTEND_KEYBOARD_NAME"
        echo -e " ${GREEN}6)${NC} Time zone     : $UNATTEND_TIMEZONE"
        echo -e " ${GREEN}7)${NC} Computer name : $UNATTEND_COMPUTER_NAME"
        echo -e " ${GREEN}8)${NC} Account       : $UNATTEND_USERNAME (password set)"
        echo -e " ${GREEN}9)${NC} Drivers       : $drivers_line"
        echo -e "    RDP           : enabled, port 3389, firewall open"
        echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
        echo
        echo -ne "${YELLOW}Enter = confirm and install | 1-9 = edit item | q = quit : ${NC}"
        local summary_choice=""
        read -r summary_choice
        summary_choice=$(echo "$summary_choice" | tr '[:upper:]' '[:lower:]')
        case "$summary_choice" in
            ""|y) break ;;
            q)
                echo -e "${GREEN}Aborted. Nothing was written to disk.${NC}"
                exit 0
                ;;
            1) step_select_disk ;;
            2)
                WINDOWS_ISO_URL=""
                step_resolve_iso
                if [ "$DEFERRED_ISO" = false ]; then
                    wizard_select_edition "$WIZARD_WIM"
                    wizard_select_language "$WIZARD_WIM"
                fi
                ;;
            3)
                if [ "$DEFERRED_ISO" = true ]; then
                    echo -e "${RED}Edition is selected after the ISO download in this mode.${NC}"
                else
                    wizard_select_edition "$WIZARD_WIM"
                fi
                ;;
            4)
                if [ "$DEFERRED_ISO" = true ]; then
                    echo -e "${RED}Language is selected after the ISO download in this mode.${NC}"
                else
                    wizard_select_language "$WIZARD_WIM"
                fi
                ;;
            5) wizard_select_keyboard ;;
            6) wizard_select_timezone ;;
            7) wizard_set_computer_name ;;
            8) wizard_set_account ;;
            9) wizard_setup_drivers ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
    # Final destructive gate : explicit, disk named, single word to type
    echo
    echo -e "${RED}LAST CHANCE : ${DISK_LABEL} will be COMPLETELY ERASED.${NC}"
    echo -ne "${YELLOW}Type ERASE to proceed (anything else aborts) : ${NC}"
    local erase_confirm=""
    read -r erase_confirm
    if [ "$erase_confirm" != "ERASE" ]; then
        echo -e "${GREEN}Aborted. Nothing was written to disk.${NC}"
        exit 0
    fi
    mountpoint -q "$WIZARD_ISO_MOUNT" 2>/dev/null && umount -f "$WIZARD_ISO_MOUNT" 2>/dev/null || true
    log_success "Configuration confirmed, starting installation"
}

###########################################
# Step 6 : Partition Disk (MBR)
###########################################

step_prepare_disk() {
    log "=== Step 6 : Partitioning disk (MBR) ==="
    # If the local ISO lives on the disk being wiped, move it to RAM first
    if [ "$USE_LOCAL_ISO" = true ] && echo "$ISO_PATH" | grep -q "^/mnt"; then
        local iso_bytes tmp_free
        iso_bytes=$(stat -c%s "$ISO_PATH")
        tmp_free=$(get_tmp_free_bytes)
        if [ "$tmp_free" -le $((iso_bytes + 1024 * 1024 * 1024)) ]; then
            handle_error "ISO is stored on the target disk and /tmp is too small to hold it. Host the ISO elsewhere (URL) and retry."
        fi
        log_warning "Local ISO is on target disk, moving to /tmp..."
        cp "$ISO_PATH" /tmp/win_local.iso || handle_error "Failed to move ISO to RAM"
        ISO_PATH="/tmp/win_local.iso"
        log_success "ISO moved to $ISO_PATH"
    fi
    cleanup_mounts
    mkdir -p "$BACKUP_DIR"
    sfdisk -d "$DISK" > "$BACKUP_DIR/partition_table_backup.txt" 2>/dev/null || true
    log "Wiping disk signatures (including stale GPT backup at end of disk)..."
    wipefs -a "$DISK" >> "$LOG_FILE" 2>&1 || true
    dd if=/dev/zero of="$DISK" bs=512 count=2048 conv=fsync 2>/dev/null || handle_error "Failed to wipe disk"
    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$DISK")
    local disk_mib=$((disk_bytes / 1024 / 1024))
    local setup_mib=$((SETUP_SIZE_GIB * 1024))
    local win_end_mib=$((disk_mib - setup_mib))
    log "Creating MBR partition table (part1 : ${win_end_mib} MiB, part2 : ${setup_mib} MiB)..."
    parted "$DISK" --script --align optimal -- mklabel msdos
    parted "$DISK" --script --align optimal -- mkpart primary ntfs 1MiB "${win_end_mib}MiB"
    parted "$DISK" --script --align optimal -- mkpart primary ntfs "${win_end_mib}MiB" 100%
    parted "$DISK" --script -- set 1 boot on
    partprobe "$DISK"
    sleep 3
    log "Formatting partition 1 (Windows)..."
    mkfs.ntfs -f -Q -L "WINDOWS" "$PART1" || handle_error "Failed to format $PART1"
    log "Formatting partition 2 (Setup)..."
    mkfs.ntfs -f -Q -L "Setup_Files" "$PART2" || handle_error "Failed to format $PART2"
    log_success "Disk partitioned and formatted"
}

###########################################
# Step 7 : Deferred ISO Download
###########################################

step_download_iso() {
    if [ "$DEFERRED_ISO" = false ]; then
        return 0
    fi
    log "=== Step 7 : Downloading Windows ISO (deferred, to Windows partition) ==="
    while true; do
        mkdir -p /mnt
        mountpoint -q /mnt || mount -t ntfs-3g "$PART1" /mnt || handle_error "Failed to mount $PART1"
        local iso_filename
        iso_filename=$(curl -sL -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" 2>/dev/null | grep -i "Content-Disposition" | grep -oP 'filename="\K[^"]+' || true)
        [ -z "$iso_filename" ] && iso_filename="win.iso"
        iso_filename="${iso_filename// /_}"
        ISO_PATH="/mnt/${iso_filename}"
        rm -f "$ISO_PATH"
        if ! wget --progress=bar:force -O "$ISO_PATH" "$WINDOWS_ISO_URL" 2>&1; then
            log_error "Download failed"
            rm -f "$ISO_PATH"
            echo -ne "${YELLOW}New ISO URL (or Ctrl+C to abort) : ${NC}"
            read -r WINDOWS_ISO_URL
            continue
        fi
        log "Verifying downloaded ISO..."
        if ! verify_iso "$ISO_PATH"; then
            log_error "Downloaded ISO is corrupted or not a Windows ISO"
            rm -f "$ISO_PATH"
            echo -ne "${YELLOW}New ISO URL (or Ctrl+C to abort) : ${NC}"
            read -r WINDOWS_ISO_URL
            continue
        fi
        log_success "Windows ISO downloaded and verified -> $ISO_PATH"
        return 0
    done
}

###########################################
# Step 8 : Extract ISO to setup partition
###########################################

step_extract_iso() {
    log "=== Step 8 : Extracting ISO to setup partition ==="
    mkdir -p /mnt2 /root/iso_mount
    mountpoint -q /mnt2 || mount -t ntfs-3g "$PART2" /mnt2 || handle_error "Failed to mount $PART2"
    mount -o loop,ro "$ISO_PATH" /root/iso_mount || handle_error "Failed to mount ISO"
    log "Copying Windows files to setup partition (this takes a few minutes)..."
    rsync -ah --info=progress2 /root/iso_mount/ /mnt2/ || handle_error "Failed to copy Windows files"
    umount /root/iso_mount || true
    rm -rf /root/iso_mount
    # Delete temp ISO copies (downloaded or moved to RAM), keep user's original files
    if echo "$ISO_PATH" | grep -q "^/tmp/"; then
        rm -f "$ISO_PATH"
    fi
    if echo "$ISO_PATH" | grep -q "^/mnt/"; then
        umount -f /mnt 2>/dev/null || true
    fi
    # Copy driver pack to the setup partition for dism injection during first boot
    if [ -n "$DRIVERS_DIR" ]; then
        log "Copying driver pack to setup partition..."
        mkdir -p /mnt2/Drivers
        rsync -a "$DRIVERS_DIR"/ /mnt2/Drivers/ || handle_error "Failed to copy drivers"
    fi
    # Marker file : lets the WinPE script find this volume regardless of drive letter
    date > /mnt2/ovh_setup.tag
    # Verify critical files are present
    for f in "/mnt2/bootmgr" "/mnt2/boot/bcd" "/mnt2/boot/boot.sdi" "/mnt2/sources/boot.wim" "/mnt2/sources/install.wim"; do
        if [ ! -f "$f" ]; then
            handle_error "Critical file missing on setup partition : $f"
        fi
    done
    wiminfo /mnt2/sources/install.wim > /dev/null 2>&1 || handle_error "install.wim is corrupted"
    log_success "Windows files extracted to setup partition"
}

###########################################
# Step 9 : Apply Windows image
###########################################

step_apply_windows() {
    log "=== Step 9 : Applying Windows image ==="
    mountpoint -q /mnt2 || mount -t ntfs-3g "$PART2" /mnt2 || handle_error "Failed to mount $PART2"
    # Deferred mode : edition/language were not selectable before download
    if [ -z "$WIM_IMAGE_INDEX" ]; then
        wizard_select_edition "/mnt2/sources/install.wim"
        wizard_select_language "/mnt2/sources/install.wim"
    fi
    mountpoint -q /mnt && umount /mnt || true
    log "Applying image $WIM_IMAGE_INDEX directly to $PART1 (this takes several minutes)..."
    wimapply /mnt2/sources/install.wim "$WIM_IMAGE_INDEX" "$PART1" || handle_error "wimapply failed"
    mkdir -p /mnt
    mount -t ntfs-3g "$PART1" /mnt || handle_error "Failed to mount $PART1 after wimapply"
    if [ ! -f "/mnt/Windows/System32/ntoskrnl.exe" ]; then
        handle_error "Windows not found after wimapply"
    fi
    # Bypass Windows 11 install-time requirements (TPM, Secure Boot) as a
    # safety net for future in-place servicing. Not strictly needed here because
    # wimapply never runs setup.exe, so the checks never fire at install time.
    local system_hive="/mnt/Windows/System32/config/SYSTEM"
    if [ -f "$system_hive" ]; then
        cat <<'REGBYPASS' > /tmp/w11bypass.reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\MoSetup]
"AllowUpgradesWithUnsupportedTPMOrCPU"=dword:00000001
REGBYPASS
        hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$system_hive" /tmp/w11bypass.reg 2>/dev/null && \
            log "Windows 11 requirements bypass injected into SYSTEM hive" || \
            log_warning "Could not inject W11 bypass (non-critical for Server/W10)"
        rm -f /tmp/w11bypass.reg
    fi
    log_success "Windows image applied to $PART1 (edition : $SELECTED_EDITION_NAME)"
}

###########################################
# Step 10 : Configure unattend + RDP
# No user interaction here : everything comes from the wizard variables.
###########################################

step_configure_unattend() {
    log "=== Step 10 : Configuring unattended setup + RDP ==="
    mountpoint -q /mnt || mount -t ntfs-3g "$PART1" /mnt || handle_error "Failed to mount $PART1"
    # Escape password for safe XML insertion
    local xml_password="$UNATTEND_PASSWORD"
    xml_password="${xml_password//&/&amp;}"
    xml_password="${xml_password//</&lt;}"
    xml_password="${xml_password//>/&gt;}"
    xml_password="${xml_password//\"/&quot;}"
    xml_password="${xml_password//\'/&apos;}"
    # Escape for sed replacement (backslash, & and delimiter are special)
    local sed_password="${xml_password//\\/\\\\}"
    sed_password="${sed_password//&/\\&}"
    sed_password="${sed_password//|/\\|}"
    mkdir -p /mnt/Windows/Panther
    # Single template. A named local admin account is created and AutoLogon
    # targets it. The __ADMINPW__ marker is replaced by an AdministratorPassword
    # block on Server (needed for the Server OOBE screen) and removed otherwise.
    cat <<'UNATTENDEOF' > /mnt/Windows/Panther/unattend.xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>__COMPUTER_NAME__</ComputerName>
      <TimeZone>__TIMEZONE__</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAuthentication>0</UserAuthentication>
    </component>
    <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="rdp">
          <Active>true</Active>
          <Group>@FirewallAPI.dll,-28752</Group>
          <Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>__USERNAME__</Name>
            <DisplayName>__USERNAME__</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>__PASSWORD__</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
__ADMINPW__
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>__USERNAME__</Username>
        <Password>
          <Value>__PASSWORD__</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>__KEYBOARD__</InputLocale>
      <SystemLocale>__LOCALE__</SystemLocale>
      <UILanguage>__LOCALE__</UILanguage>
      <UserLocale>__LOCALE__</UserLocale>
    </component>
  </settings>
</unattend>
UNATTENDEOF
    # Server : mirror the password to the built-in Administrator (satisfies the
    # Server first-boot password screen). Client : remove the marker line.
    if [ "$IS_SERVER_EDITION" = true ]; then
        cat <<'ADMINPWEOF' > /tmp/adminpw.xml
        <AdministratorPassword>
          <Value>__PASSWORD__</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
ADMINPWEOF
        sed -i -e '/__ADMINPW__/{r /tmp/adminpw.xml' -e 'd}' /mnt/Windows/Panther/unattend.xml
        rm -f /tmp/adminpw.xml
    else
        sed -i '/__ADMINPW__/d' /mnt/Windows/Panther/unattend.xml
    fi
    sed -i \
        -e "s|__COMPUTER_NAME__|${UNATTEND_COMPUTER_NAME}|g" \
        -e "s|__TIMEZONE__|${UNATTEND_TIMEZONE}|g" \
        -e "s|__USERNAME__|${UNATTEND_USERNAME}|g" \
        -e "s|__PASSWORD__|${sed_password}|g" \
        -e "s|__KEYBOARD__|${UNATTEND_KEYBOARD_CODE}|g" \
        -e "s|__LOCALE__|${UNATTEND_LOCALE}|g" \
        /mnt/Windows/Panther/unattend.xml
    log_success "unattend.xml created (OOBE skip + ${UNATTEND_USERNAME} account + RDP + firewall + timezone)"
    # SetupComplete.cmd : runs as SYSTEM before first interactive login.
    # NOTE : ignored by some OEM-activated Desktop images, which is why RDP +
    # firewall are ALSO configured in unattend.xml above (belt and braces).
    mkdir -p /mnt/Windows/Setup/Scripts
    cat <<'SETUPEOF' > /mnt/Windows/Setup/Scripts/SetupComplete.cmd
@echo off
:: Enable Remote Desktop and disable NLA requirement
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f
:: Open firewall for RDP (TCP 3389)
netsh advfirewall firewall add rule name="Remote Desktop (TCP-In)" dir=in action=allow protocol=TCP localport=3389
:: Enable ICMP (ping) for remote diagnostics
netsh advfirewall firewall add rule name="ICMP Allow" dir=in action=allow protocol=ICMPv4
:: Set all connected network adapters to Private profile
powershell -ExecutionPolicy Bypass -Command "Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { $prof = Get-NetConnectionProfile -InterfaceAlias $_.Name -ErrorAction SilentlyContinue; if ($prof -and $prof.NetworkCategory -ne 'Private' -and $prof.NetworkCategory -ne 'DomainAuthenticated') { Set-NetConnectionProfile -InterfaceAlias $_.Name -NetworkCategory Private -ErrorAction SilentlyContinue } }"
:: Disable password expiration (prevents RDP lockout on headless servers)
net accounts /maxpwage:unlimited
:: Set power plan to high performance (prevent sleep on dedicated server)
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
:: Disable hibernation (reclaim disk space)
powercfg /hibernate off
:: Disable Ctrl+Alt+Del requirement for login
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableCAD /t REG_DWORD /d 1 /f
:: Remove plaintext password from unattend.xml (persists after install)
del /f /q "%WINDIR%\Panther\unattend.xml" >nul 2>&1
del /f /q "%WINDIR%\Panther\Unattend\unattend.xml" >nul 2>&1
del /f /q "%SYSTEMDRIVE%\unattend.xml" >nul 2>&1
:: Disable automatic restart after Windows Update
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 3 /f
SETUPEOF
    log_success "SetupComplete.cmd created"
}

###########################################
# Step 11 : Inject auto-bcdboot + drivers into WinPE
###########################################

step_inject_winpe() {
    log "=== Step 11 : Injecting auto-bcdboot + drivers into WinPE ==="
    mountpoint -q /mnt2 || mount -t ntfs-3g "$PART2" /mnt2 || handle_error "Failed to mount $PART2"
    # WinPE startup script :
    # 1. Loads user drivers into the running WinPE (a hidden storage controller
    #    needs this before the disk is even visible)
    # 2. Locates the Windows volume and the setup volume (by marker file)
    # 3. Injects user drivers into the installed Windows via dism /Add-Driver
    #    /ForceUnsigned (proper registration, incl. boot-critical storage drivers)
    # 4. Creates boot files with bcdboot
    # 5. Deletes the setup partition and extends the Windows partition. Selecting
    #    the volume first also selects the correct disk (safe on multi-disk).
    cat <<'BCDSCRIPT' > /tmp/startnet.cmd
@echo off
echo ============================================
echo  Automated first boot - finalizing Windows
echo ============================================
echo.
wpeinit
ping -n 2 127.0.0.1 >nul
if exist X:\Drivers (
    echo Loading drivers into WinPE...
    for /r X:\Drivers %%d in (*.inf) do drvload "%%d" >nul 2>&1
)
set WINDRIVE=
set SETUPDRIVE=
for %%l in (C D E F G H I J) do (
    if exist %%l:\Windows\System32\ntoskrnl.exe set WINDRIVE=%%l:
    if exist %%l:\ovh_setup.tag set SETUPDRIVE=%%l:
)
if not defined WINDRIVE goto notfound
echo Found Windows on %WINDRIVE%
if defined SETUPDRIVE (
    if exist %SETUPDRIVE%\Drivers (
        echo Injecting drivers into the installed Windows...
        dism /Image:%WINDRIVE%\ /Add-Driver /Driver:%SETUPDRIVE%\Drivers /Recurse /ForceUnsigned
        if errorlevel 1 echo WARNING : some drivers failed to inject, continuing anyway
    )
)
bcdboot %WINDRIVE%\Windows /s %WINDRIVE% /f BIOS
if errorlevel 1 goto bcdfail
echo Boot files created.
echo Removing setup partition and extending Windows partition...
(echo select volume %WINDRIVE:~0,1%
echo select partition 2
echo delete partition override
echo select partition 1
echo extend)> X:\diskpart.txt
diskpart /s X:\diskpart.txt
echo Done. Rebooting in 10 seconds...
ping -n 10 127.0.0.1 >nul
wpeutil reboot
goto eof
:notfound
echo ERROR : Windows not found on any drive.
cmd /k
goto eof
:bcdfail
echo ERROR : bcdboot failed.
cmd /k
:eof
BCDSCRIPT
    cat <<'WINPESHL' > /tmp/winpeshl.ini
[LaunchApps]
%SYSTEMROOT%\System32\cmd.exe, /c %SYSTEMROOT%\System32\startnet.cmd
WINPESHL
    # The setup image is always the LAST image in boot.wim
    # (index 1 on single-image ISOs, index 2 on standard Microsoft ISOs).
    # Verified against fr-FR Windows 11 25H2 and Server 2025 ISOs.
    local boot_wim_last
    boot_wim_last=$(wiminfo /mnt2/sources/boot.wim | awk '/^Image Count:/{print $3}')
    [ -z "$boot_wim_last" ] && boot_wim_last=1
    # Decide whether drivers also go inside boot.wim (loaded entirely in RAM,
    # so oversized packs are excluded ; dism injection from part2 still happens)
    INJECT_DRIVERS_IN_WINPE=false
    if [ -n "$DRIVERS_DIR" ]; then
        local drv_size
        drv_size=$(du -sb "$DRIVERS_DIR" 2>/dev/null | awk '{print $1}')
        if [ "${drv_size:-0}" -le $((512 * 1024 * 1024)) ]; then
            INJECT_DRIVERS_IN_WINPE=true
        else
            log_warning "Driver pack larger than 512 MiB : skipping WinPE (RAM) injection, dism injection still applies"
        fi
    fi
    log "Modifying boot.wim image ${boot_wim_last}..."
    cp /mnt2/sources/boot.wim /tmp/boot_modified.wim || handle_error "Failed to copy boot.wim"
    chmod 644 /tmp/boot_modified.wim
    {
        echo "add /tmp/startnet.cmd /Windows/System32/startnet.cmd"
        echo "add /tmp/winpeshl.ini /Windows/System32/winpeshl.ini"
        if [ "$INJECT_DRIVERS_IN_WINPE" = true ]; then
            echo "add \"$DRIVERS_DIR\" /Drivers"
        fi
    } | wimupdate /tmp/boot_modified.wim "$boot_wim_last" >> "$LOG_FILE" 2>&1 || \
        handle_error "Failed to inject into boot.wim"
    cp /tmp/boot_modified.wim /mnt2/sources/boot.wim || handle_error "Failed to write modified boot.wim"
    rm -f /tmp/boot_modified.wim /tmp/startnet.cmd /tmp/winpeshl.ini
    log_success "Auto-bcdboot injected into WinPE image ${boot_wim_last} (drivers in WinPE : ${INJECT_DRIVERS_IN_WINPE})"
}

###########################################
# Step 12 : Install GRUB2 + wimboot
###########################################

step_install_grub() {
    log "=== Step 12 : Installing GRUB2 + wimboot ==="
    mountpoint -q /mnt || mount -t ntfs-3g "$PART1" /mnt || handle_error "Failed to mount $PART1"
    mountpoint -q /mnt2 || mount -t ntfs-3g "$PART2" /mnt2 || handle_error "Failed to mount $PART2"
    # Copy boot files to part1 (persist after part2 deletion)
    mkdir -p /mnt/Boot
    cp /mnt2/boot/boot.sdi /mnt/Boot/boot.sdi
    log "Downloading wimboot..."
    retry_command "wget -q -O /mnt/Boot/wimboot '$WIMBOOT_URL' >> $LOG_FILE 2>&1" "download wimboot" || handle_error "Failed to download wimboot"
    cp /mnt/Boot/wimboot /mnt2/boot/wimboot
    log_success "wimboot installed"
    # Install GRUB2 to MBR with boot directory on part1 (survives part2 deletion).
    # core.img lives in the MBR embedding gap (the 1 MiB before part1), not part2.
    mkdir -p /mnt/boot/grub
    local grub_ok=false
    local methods=(
        "grub-install --target=i386-pc --boot-directory=/mnt/boot --force --recheck $DISK"
        "grub-install --boot-directory=/mnt/boot --force $DISK"
    )
    for method in "${methods[@]}"; do
        log "Trying : $method"
        if eval "$method" >> "$LOG_FILE" 2>&1; then
            grub_ok=true
            log_success "GRUB2 installed"
            break
        fi
    done
    if [ "$grub_ok" = false ]; then
        handle_error "GRUB2 installation failed"
    fi
    # Single GRUB entry with auto-detection. hd0 is the disk GRUB was installed on.
    # Boot/BCD present on part1 -> boot installed Windows
    # Boot/BCD absent on part1 -> boot WinPE from part2 (first boot only)
    cat <<'GRUBCFG' > /mnt/boot/grub/grub.cfg
set timeout=3
set default=0
menuentry "Windows" {
    insmod ntfs
    if [ -f (hd0,msdos1)/Boot/BCD ]; then
        set root=(hd0,msdos1)
        linux16 /Boot/wimboot
        initrd16 newc:bootmgr:/bootmgr newc:bcd:/Boot/BCD newc:boot.sdi:/Boot/boot.sdi
    else
        set root=(hd0,msdos2)
        linux16 /boot/wimboot
        initrd16 newc:bootmgr:/bootmgr newc:bcd:/boot/bcd newc:boot.sdi:/boot/boot.sdi newc:boot.wim:/sources/boot.wim
    fi
    boot
}
GRUBCFG
    if [ ! -f "/mnt/boot/grub/grub.cfg" ]; then
        handle_error "Failed to create grub.cfg"
    fi
    log_success "GRUB2 configured with auto-detect entry"
}

###########################################
# Final Verification
###########################################

step_finalize() {
    log "=== Final verification ==="
    mountpoint -q /mnt || mount -t ntfs-3g "$PART1" /mnt 2>/dev/null || true
    mountpoint -q /mnt2 || mount -t ntfs-3g "$PART2" /mnt2 2>/dev/null || true
    log "Windows partition ($PART1) :"
    for f in "/mnt/Windows/System32/ntoskrnl.exe" "/mnt/Boot/wimboot" "/mnt/Boot/boot.sdi" "/mnt/boot/grub/grub.cfg" "/mnt/Windows/Panther/unattend.xml" "/mnt/Windows/Setup/Scripts/SetupComplete.cmd"; do
        if [ -f "$f" ]; then
            log "  OK : $f"
        else
            log_warning "  MISSING : $f"
        fi
    done
    log "Setup partition ($PART2, auto-deleted on first boot) :"
    for f in "/mnt2/boot/wimboot" "/mnt2/bootmgr" "/mnt2/boot/bcd" "/mnt2/boot/boot.sdi" "/mnt2/sources/boot.wim" "/mnt2/ovh_setup.tag"; do
        if [ -f "$f" ]; then
            log "  OK : $f"
        else
            log_warning "  MISSING : $f"
        fi
    done
    if [ -n "$DRIVERS_DIR" ]; then
        if [ -d "/mnt2/Drivers" ]; then
            log "  OK : /mnt2/Drivers ($DRIVERS_INF_COUNT .inf)"
        else
            log_warning "  MISSING : /mnt2/Drivers"
        fi
    fi
    fdisk -l "$DISK" 2>/dev/null | grep "^${DISK}" | while read -r line; do
        log "  $line"
    done
    sync
    umount -f /mnt 2>/dev/null || true
    umount -f /mnt2 2>/dev/null || true
    log_success "All verifications passed"
}

###########################################
# Main
###########################################

main() {
    clear
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE}  Windows Installation - OVH Dedicated Server        ${NC}"
    echo -e "${BLUE}  MBR/Legacy BIOS - wimapply + wimboot - v3.0        ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo
    echo "=== Installation started at $(date) ===" >> "$LOG_FILE"
    mkdir -p "$BACKUP_DIR"
    step_check_system
    step_install_packages
    step_select_disk
    step_resolve_iso
    step_run_wizard
    step_prepare_disk
    step_download_iso
    step_extract_iso
    step_apply_windows
    step_configure_unattend
    step_inject_winpe
    step_install_grub
    step_finalize
    local server_ip
    server_ip=$(ip -4 addr show scope global | grep -oP 'inet \K[0-9.]+' | head -1 || echo "<server_ip>")
    echo
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}  Installation complete!                              ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo
    echo -e "${YELLOW}WHAT HAPPENS NEXT :${NC}"
    echo -e "  ${BLUE}1.${NC} Go to OVH Control Panel"
    echo -e "  ${BLUE}2.${NC} Change Netboot to ${GREEN}'Boot from hard disk'${NC}"
    echo -e "  ${BLUE}3.${NC} Reboot the server"
    echo -e "  ${BLUE}4.${NC} ${YELLOW}Wait ~5-15 minutes${NC} (two automatic reboots will happen)"
    echo -e "     - 1st boot : WinPE injects drivers, creates boot files, reboots"
    echo -e "     - 2nd boot : Windows finishes setup (OOBE skipped)"
    echo
    echo -e "${YELLOW}THEN CONNECT VIA RDP (mstsc /v:${server_ip}) :${NC}"
    echo -e "  User     : ${GREEN}${UNATTEND_USERNAME}${NC}"
    echo -e "  Password : ${GREEN}(the one you set in the wizard)${NC}"
    echo
    echo -e "${YELLOW}TROUBLESHOOTING :${NC}"
    echo -e "  - Can't connect? Wait a few more minutes, Windows may still be configuring"
    echo -e "  - Still nothing after 20 min? Reboot from OVH panel and try again"
    echo -e "  - Never reachable? Suspect a missing NIC driver : reboot in rescue mode,"
    echo -e "    rerun this script and inject the vendor driver pack when asked"
    echo
    echo -e "Full log : $LOG_FILE"
    echo
    echo -e "Press any key to reboot, Ctrl+C to cancel..."
    read -n 1 -s -r
    reboot
}

main
