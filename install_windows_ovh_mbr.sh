#!/bin/bash

###########################################
#  Windows ISO Installation               #
#  OVH Dedicated Server - MBR/Legacy      #
###########################################

# v1.0

# HOW IT WORKS :
# 1. Script partitions disk (sda1=Windows, sda2=setup)
# 2. Extracts ISO to sda2, applies Windows image to sda1 via wimapply
# 3. Injects auto-bcdboot into boot.wim (replaces setup.exe with bcdboot script)
# 4. GRUB2 + wimboot handles booting (only method working with OVH iPXE)
# 5. Single GRUB entry auto-detects boot phase :
#    - No Boot/BCD on sda1 -> boots modified WinPE -> auto bcdboot -> auto reboot
#    - Boot/BCD on sda1 -> boots installed Windows directly
#
# BOOT CHAIN : iPXE -> sanboot -> GRUB2 -> wimboot -> bootmgr + BCD -> Windows
#
# FIRST BOOT : WinPE loads, runs bcdboot automatically, reboots by itself
# SECOND BOOT : Windows OOBE (language, admin password, etc.)
# NO MANUAL INTERVENTION BETWEEN BOOTS
#
# WHY WIMBOOT :
# iPXE sanboot cannot chainload Windows MBR/VBR.
# GRUB2 ntldr /bootmgr freezes. grub4dos chainloader gives "BOOTMGR corrupt".
# wimboot loads bootmgr + BCD into a ramdisk, bypassing iPXE disk access issues.
#
# WHY WIMAPPLY :
# WinPE booted via wimboot runs in RAM and cannot find install.wim on disk.
# wimapply (wimlib) applies the Windows image directly from Linux.

# USAGE :
# scp install_windows_ovh_mbr.sh root@YOUR_IP:/root/
# ssh root@YOUR_IP
# bash /root/install_windows_ovh_mbr.sh                   # prompts for URL
# bash /root/install_windows_ovh_mbr.sh "https://iso-url" # with URL

# AFTER SCRIPT COMPLETES :
# 1. Change Netboot to "Boot from hard disk" in OVH panel
# 2. Reboot the server
# 3. First boot : WinPE creates boot files automatically, reboots
# 4. Second boot : Windows OOBE starts
#
# sda2 (setup partition) is automatically deleted and sda1 extended
# during the first boot WinPE phase. No manual cleanup needed.

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
DISK="/dev/sda"
LOG_FILE="/root/windows_install.log"
BACKUP_DIR="/root/backup"
MAX_RETRIES=3
WIMBOOT_URL="https://github.com/ipxe/wimboot/releases/latest/download/wimboot"
WIM_IMAGE_INDEX=""
SETUP_SIZE_GIB=25
USE_LOCAL_ISO=false

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
    fdisk -l "$DISK" > "$BACKUP_DIR/partition_state.txt" 2>/dev/null || true
    for mp in "/mnt" "/mnt2" "/root/iso_mount"; do
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
    for mp in "/mnt" "/mnt2" "/root/iso_mount"; do
        mountpoint -q "$mp" 2>/dev/null && umount -f "$mp" 2>/dev/null || true
    done
    # Unmount all partitions on target disk
    for part in $(mount | grep "$DISK" | awk '{print $1}'); do
        umount -f "$part" 2>/dev/null || true
    done
    # Disable swap on target disk
    for part in $(swapon --show=NAME --noheadings 2>/dev/null | grep "$DISK"); do
        swapoff "$part" 2>/dev/null || true
    done
}

###########################################
# Step 1 : System Checks
###########################################

step_check_system() {
    log "=== Step 1/9 : System checks ==="
    if [ "$EUID" -ne 0 ]; then
        handle_error "Script must be run as root"
    fi
    if [ -d "/sys/firmware/efi" ]; then
        handle_error "UEFI detected. This script only supports Legacy BIOS (MBR). Aborting."
    fi
    if [ ! -b "$DISK" ]; then
        handle_error "Disk $DISK not found"
    fi
    local disk_size
    disk_size=$(blockdev --getsize64 "$DISK")
    local disk_gb=$((disk_size / 1024 / 1024 / 1024))
    log "Disk : $DISK (${disk_gb}GB)"
    if [ "$disk_gb" -lt 40 ]; then
        handle_error "Disk too small : ${disk_gb}GB (minimum 40GB)"
    fi
    local available_mem
    available_mem=$(free -g | awk '/^Mem:/{print $7}')
    log "Available RAM : ${available_mem}GB"
    if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
        handle_error "No internet connection"
    fi
    log_success "System checks passed (${disk_gb}GB disk, ${available_mem}GB RAM)"
}

###########################################
# Step 2 : Install Packages
###########################################

step_install_packages() {
    log "=== Step 2/9 : Installing packages ==="
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
# Step 3 : Resolve ISO source
###########################################

step_resolve_iso() {
    log "=== Step 3/9 : Resolving ISO source ==="
    if [ -n "$WINDOWS_ISO_URL" ]; then
        log "URL provided via argument : $WINDOWS_ISO_URL"
    else
        # Scan for local ISO files
        local iso_files=()
        while IFS= read -r f; do
            # Verify ISO magic bytes (CD001 at offset 0x8001)
            if dd if="$f" bs=1 skip=32769 count=5 2>/dev/null | grep -q "CD001"; then
                iso_files+=("$f")
            fi
        done < <(find /root /tmp /home /mnt 2>/dev/null -maxdepth 2 -type f -iname "*.iso" -size +1G 2>/dev/null | sort)
        if [ "${#iso_files[@]}" -gt 0 ]; then
            echo
            echo -e "${BLUE}Local ISO files detected :${NC}"
            echo
            local letters="abcdefghijklmnopqrstuvwxyz"
            local i=0
            for f in "${iso_files[@]}"; do
                local letter="${letters:$i:1}"
                local fsize
                fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
                local fmb=$((fsize / 1024 / 1024))
                echo -e "  ${GREEN}${letter})${NC} $f (${fmb} MB)"
                i=$((i + 1))
            done
            echo
            echo -e "  ${GREEN}u)${NC} Enter a download URL instead"
            echo
            local valid=false
            while [ "$valid" = false ]; do
                echo -ne "${YELLOW}Select ISO source (letter) : ${NC}"
                read -r -n 1 choice
                echo
                choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
                if [ "$choice" = "u" ]; then
                    valid=true
                else
                    local idx=0
                    local j=0
                    while [ "$j" -lt "${#letters}" ]; do
                        if [ "${letters:$j:1}" = "$choice" ]; then
                            idx=$j
                            break
                        fi
                        j=$((j + 1))
                    done
                    if [ "$idx" -lt "${#iso_files[@]}" ] && [ "$choice" = "${letters:$idx:1}" ]; then
                        ISO_PATH="${iso_files[$idx]}"
                        USE_LOCAL_ISO=true
                        valid=true
                    else
                        echo -e "${RED}Invalid choice.${NC}"
                    fi
                fi
            done
        fi
        # Prompt for URL if no local ISO selected
        if [ "$USE_LOCAL_ISO" = false ] && [ -z "$WINDOWS_ISO_URL" ]; then
            while [ -z "$WINDOWS_ISO_URL" ]; do
                echo
                echo -e "${YELLOW}Enter the Windows ISO download URL :${NC}"
                read -r WINDOWS_ISO_URL
                if [ -z "$WINDOWS_ISO_URL" ]; then
                    log_warning "Empty URL, try again"
                fi
            done
        fi
    fi
    # Determine setup partition size
    if [ "$USE_LOCAL_ISO" = true ]; then
        local iso_size
        iso_size=$(stat -c%s "$ISO_PATH" 2>/dev/null || echo 0)
        local iso_gib=$((iso_size / 1024 / 1024 / 1024))
        SETUP_SIZE_GIB=$((iso_gib + 2))
        log "Local ISO : $ISO_PATH ($(( iso_size / 1024 / 1024 )) MB)"
        log "Setup partition size : ${SETUP_SIZE_GIB} GiB (ISO + 2 GiB margin)"
    elif [ -n "$WINDOWS_ISO_URL" ]; then
        local remote_size=0
        # Try HEAD request first
        remote_size=$(curl -sLI "$WINDOWS_ISO_URL" | grep -i "Content-Length" | tail -1 | awk '{print $2}' | tr -d '\r' || echo 0)
        # If HEAD blocked, try 1-byte range GET (returns Content-Range with total size)
        if [ "$remote_size" -le 0 ] 2>/dev/null; then
            remote_size=$(curl -sL -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" | grep -i "Content-Range" | grep -oP '/\K[0-9]+' || echo 0)
        fi
        if [ "$remote_size" -gt 0 ]; then
            local remote_mb=$((remote_size / 1024 / 1024))
            local remote_gib=$((remote_size / 1024 / 1024 / 1024))
            SETUP_SIZE_GIB=$((remote_gib + 2))
            log "Remote ISO size : ${remote_mb} MB"
            log "Setup partition size : ${SETUP_SIZE_GIB} GiB (ISO + 2 GiB margin)"
        else
            SETUP_SIZE_GIB=25
            log_warning "Could not determine ISO size, using default ${SETUP_SIZE_GIB} GiB for setup partition"
        fi
    fi
    # Verify ISO integrity before wiping anything
    if [ "$USE_LOCAL_ISO" = true ]; then
        local iso_ok=false
        mkdir -p /root/iso_check
        if mount -o loop,ro "$ISO_PATH" /root/iso_check 2>/dev/null; then
            iso_ok=true
            for f in "/root/iso_check/bootmgr" "/root/iso_check/sources/boot.wim" "/root/iso_check/sources/install.wim"; do
                if [ ! -f "$f" ]; then
                    iso_ok=false
                    break
                fi
            done
            if [ "$iso_ok" = true ]; then
                wiminfo /root/iso_check/sources/install.wim > /dev/null 2>&1 || iso_ok=false
            fi
            umount /root/iso_check 2>/dev/null || true
        fi
        rm -rf /root/iso_check
        if [ "$iso_ok" = false ]; then
            log_error "ISO is corrupted or truncated : $ISO_PATH"
            ISO_PATH=""
            WINDOWS_ISO_URL=""
            USE_LOCAL_ISO=false
            step_resolve_iso
            return
        fi
        log_success "ISO integrity verified"
    fi
}

###########################################
# Step 4 : Partition Disk (MBR)
###########################################

step_prepare_disk() {
    log "=== Step 4/9 : Partitioning disk (MBR) ==="
    # If local ISO is on the disk being wiped, move it to RAM first
    if [ "$USE_LOCAL_ISO" = true ] && echo "$ISO_PATH" | grep -q "^/mnt"; then
        log_warning "Local ISO is on target disk, moving to /tmp..."
        cp "$ISO_PATH" /tmp/win_local.iso || handle_error "Failed to move ISO to RAM (not enough RAM?)"
        ISO_PATH="/tmp/win_local.iso"
        log_success "ISO moved to $ISO_PATH"
    fi
    cleanup_mounts
    mkdir -p "$BACKUP_DIR"
    sfdisk -d "$DISK" > "$BACKUP_DIR/partition_table_backup.txt" 2>/dev/null || true
    log "Wiping disk signatures..."
    dd if=/dev/zero of="$DISK" bs=512 count=2048 conv=fsync 2>/dev/null || handle_error "Failed to wipe disk"
    local disk_bytes
    disk_bytes=$(blockdev --getsize64 "$DISK")
    local disk_mib=$((disk_bytes / 1024 / 1024))
    local setup_mib=$((SETUP_SIZE_GIB * 1024))
    local win_end_mib=$((disk_mib - setup_mib))
    log "Creating MBR partition table (sda1 : ${win_end_mib} MiB, sda2 : ${setup_mib} MiB)..."
    parted "$DISK" --script --align optimal -- mklabel msdos
    parted "$DISK" --script --align optimal -- mkpart primary ntfs 1MiB "${win_end_mib}MiB"
    parted "$DISK" --script --align optimal -- mkpart primary ntfs "${win_end_mib}MiB" 100%
    parted "$DISK" --script -- set 1 boot on
    partprobe "$DISK"
    sleep 3
    log "Formatting partition 1 (Windows)..."
    mkfs.ntfs -f -Q -L "WINDOWS" "${DISK}1" || handle_error "Failed to format ${DISK}1"
    log "Formatting partition 2 (Setup)..."
    mkfs.ntfs -f -Q -L "Setup_Files" "${DISK}2" || handle_error "Failed to format ${DISK}2"
    log_success "Disk partitioned and formatted"
}

###########################################
# Step 5 : Download Windows ISO
###########################################

step_download_iso() {
    log "=== Step 5/9 : Downloading Windows ISO ==="
    if [ "$USE_LOCAL_ISO" = true ]; then
        log "Using local ISO : $ISO_PATH (skipping download)"
        return 0
    fi
    local iso_valid=false
    while [ "$iso_valid" = false ]; do
        if [ -z "$WINDOWS_ISO_URL" ]; then
            echo
            echo -e "${YELLOW}Enter the Windows ISO download URL :${NC}"
            read -r WINDOWS_ISO_URL
        fi
        if [ -z "$WINDOWS_ISO_URL" ]; then
            log_warning "Empty URL, try again"
            continue
        fi
        # Determine ISO size for RAM check
        local available_ram_bytes
        available_ram_bytes=$(free -b | awk '/^Mem:/{print $7}')
        local estimated_iso
        estimated_iso=$(curl -sLI "$WINDOWS_ISO_URL" | grep -i "Content-Length" | tail -1 | awk '{print $2}' | tr -d '\r' || echo 0)
        if [ "$estimated_iso" -le 0 ] 2>/dev/null; then
            estimated_iso=$(curl -sL -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" | grep -i "Content-Range" | grep -oP '/\K[0-9]+' || echo 0)
        fi
        if [ "$estimated_iso" -le 0 ] 2>/dev/null; then
            estimated_iso=$((SETUP_SIZE_GIB * 1024 * 1024 * 1024))
        fi
        # Try to get real filename from server
        local iso_filename
        local headers
        headers=$(curl -sL -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" 2>/dev/null || true)
        iso_filename=$(echo "$headers" | grep -i "Content-Disposition" | grep -oP 'filename="\K[^"]+' || true)
        [ -z "$iso_filename" ] && iso_filename="win.iso"
        iso_filename="${iso_filename// /_}"
        # Choose download location based on available RAM
        local margin=$((4 * 1024 * 1024 * 1024))
        if [ "$available_ram_bytes" -gt $((estimated_iso + margin)) ]; then
            log "Enough RAM, downloading to /tmp (RAM)"
            ISO_PATH="/tmp/${iso_filename}"
        else
            log "Not enough RAM, downloading to sda1"
            mkdir -p /mnt
            mountpoint -q /mnt || mount -t ntfs-3g "${DISK}1" /mnt || handle_error "Failed to mount ${DISK}1"
            ISO_PATH="/mnt/${iso_filename}"
        fi
        rm -f "$ISO_PATH"
        if wget --progress=bar:force -O "$ISO_PATH" "$WINDOWS_ISO_URL" 2>&1; then
            local file_size
            file_size=$(stat -c%s "$ISO_PATH" 2>/dev/null || echo 0)
            local file_mb=$((file_size / 1024 / 1024))
            if [ "$file_size" -gt 1000000000 ]; then
                log_success "Windows ISO downloaded (${file_mb} MB) -> $ISO_PATH"
                iso_valid=true
            else
                log_error "File too small (${file_mb} MB) - expected at least 1 GB"
                rm -f "$ISO_PATH"
                WINDOWS_ISO_URL=""
            fi
        else
            log_error "Download failed"
            rm -f "$ISO_PATH"
            WINDOWS_ISO_URL=""
        fi
    done
}

###########################################
# Step 6 : Extract ISO to sda2
###########################################

step_extract_iso() {
    log "=== Step 6/9 : Extracting ISO to sda2 ==="
    mkdir -p /mnt2 /root/iso_mount
    mountpoint -q /mnt2 || mount -t ntfs-3g "${DISK}2" /mnt2 || handle_error "Failed to mount ${DISK}2"
    mount -o loop "$ISO_PATH" /root/iso_mount || handle_error "Failed to mount ISO"
    log "Copying Windows files to sda2 (this takes a few minutes)..."
    rsync -ah --info=progress2 /root/iso_mount/ /mnt2/ || handle_error "Failed to copy Windows files"
    umount /root/iso_mount || true
    rm -rf /root/iso_mount
    # Delete temp ISO copies (downloaded or moved to RAM), keep user's original files
    if echo "$ISO_PATH" | grep -q "^/tmp/"; then
        rm -f "$ISO_PATH"
    fi
    if echo "$ISO_PATH" | grep -q "/mnt/"; then
        umount -f /mnt 2>/dev/null || true
    fi
    # Verify critical files are present on sda2
    for f in "/mnt2/bootmgr" "/mnt2/boot/bcd" "/mnt2/boot/boot.sdi" "/mnt2/sources/boot.wim" "/mnt2/sources/install.wim"; do
        if [ ! -f "$f" ]; then
            handle_error "Critical file missing on sda2 : $f (ISO may be truncated or corrupted)"
        fi
    done
    wiminfo /mnt2/sources/install.wim > /dev/null 2>&1 || handle_error "install.wim is corrupted (ISO likely truncated)"
    log_success "Windows files extracted to sda2"
}

###########################################
# Step 7 : Apply Windows image to sda1
###########################################

step_apply_windows() {
    log "=== Step 7/9 : Applying Windows image to sda1 ==="
    mountpoint -q /mnt2 || mount -t ntfs-3g "${DISK}2" /mnt2 || handle_error "Failed to mount ${DISK}2"
    # Single wiminfo call, parse everything from cache
    local wim_info_all
    wim_info_all=$(wiminfo /mnt2/sources/install.wim)
    local image_count
    image_count=$(echo "$wim_info_all" | grep "^Image Count:" | awk '{print $3}')
    if [ -z "$image_count" ] || [ "$image_count" -eq 0 ]; then
        handle_error "No images found in install.wim"
    fi
    # Parse display names and descriptions
    local -a display_names=()
    local -a descriptions=()
    while IFS= read -r line; do
        display_names+=("$line")
    done < <(echo "$wim_info_all" | grep "^Display Name:" | sed 's/^Display Name:[[:space:]]*//')
    while IFS= read -r line; do
        descriptions+=("$line")
    done < <(echo "$wim_info_all" | grep "^Display Description:" | sed 's/^Display Description:[[:space:]]*//')
    echo
    echo -e "${BLUE}Available Windows editions :${NC}"
    echo
    local letters="abcdefghijklmnopqrstuvwxyz"
    local i=0
    while [ "$i" -lt "$image_count" ]; do
        local letter="${letters:$i:1}"
        echo -e "  ${GREEN}${letter})${NC} ${display_names[$i]}"
        if [ "$i" -lt "${#descriptions[@]}" ] && [ -n "${descriptions[$i]}" ]; then
            echo -e "     ${YELLOW}${descriptions[$i]}${NC}"
        fi
        echo
        i=$((i + 1))
    done
    local valid_choice=false
    while [ "$valid_choice" = false ]; do
        echo -ne "${YELLOW}Select edition (letter) : ${NC}"
        read -r -n 1 chosen_letter
        echo
        chosen_letter=$(echo "$chosen_letter" | tr '[:upper:]' '[:lower:]')
        local idx=0
        local j=0
        while [ "$j" -lt "${#letters}" ]; do
            if [ "${letters:$j:1}" = "$chosen_letter" ]; then
                idx=$((j + 1))
                break
            fi
            j=$((j + 1))
        done
        if [ "$idx" -ge 1 ] && [ "$idx" -le "$image_count" ]; then
            WIM_IMAGE_INDEX="$idx"
            valid_choice=true
        else
            echo -e "${RED}Invalid choice. Pick a letter from a to ${letters:$((image_count-1)):1}.${NC}"
        fi
    done
    log "Selected : ${display_names[$((WIM_IMAGE_INDEX-1))]} (index $WIM_IMAGE_INDEX)"
    mountpoint -q /mnt && umount /mnt
    log "Applying image directly to ${DISK}1 (this takes several minutes)..."
    wimapply /mnt2/sources/install.wim "$WIM_IMAGE_INDEX" "${DISK}1" || handle_error "wimapply failed"
    mount -t ntfs-3g "${DISK}1" /mnt || handle_error "Failed to mount ${DISK}1 after wimapply"
    if [ ! -f "/mnt/Windows/System32/ntoskrnl.exe" ]; then
        handle_error "Windows not found after wimapply"
    fi
    log_success "Windows image applied to sda1 (with full NTFS attributes)"
}

###########################################
# Step 8 : Inject auto-bcdboot into WinPE
###########################################

step_inject_bcdboot() {
    log "=== Step 8/9 : Injecting auto-bcdboot into WinPE ==="
    mountpoint -q /mnt2 || mount -t ntfs-3g "${DISK}2" /mnt2 || handle_error "Failed to mount ${DISK}2"
    # WinPE startup script : finds Windows, runs bcdboot, deletes sda2, extends sda1, reboots
    cat <<'BCDSCRIPT' > /tmp/startnet.cmd
@echo off
echo ============================================
echo  Auto-bcdboot - Creating boot files
echo ============================================
echo.
wpeinit
ping -n 2 127.0.0.1 >nul
set WINDRIVE=
if exist C:\Windows\System32\ntoskrnl.exe set WINDRIVE=C:
if exist D:\Windows\System32\ntoskrnl.exe set WINDRIVE=D:
if exist E:\Windows\System32\ntoskrnl.exe set WINDRIVE=E:
if exist F:\Windows\System32\ntoskrnl.exe set WINDRIVE=F:
if exist G:\Windows\System32\ntoskrnl.exe set WINDRIVE=G:
if exist H:\Windows\System32\ntoskrnl.exe set WINDRIVE=H:
if not defined WINDRIVE goto notfound
echo Found Windows on %WINDRIVE%
bcdboot %WINDRIVE%\Windows /s %WINDRIVE% /f BIOS
if errorlevel 1 goto bcdfail
echo Boot files created.
echo Removing setup partition and extending Windows partition...
(echo select disk 0
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
    # WinPE shell configuration : launch startnet.cmd automatically
    cat <<'WINPESHL' > /tmp/winpeshl.ini
[LaunchApps]
%SYSTEMROOT%\System32\cmd.exe, /c %SYSTEMROOT%\System32\startnet.cmd
WINPESHL
    log "Modifying boot.wim image 2..."
    cp /mnt2/sources/boot.wim /tmp/boot_modified.wim || handle_error "Failed to copy boot.wim"
    chmod 644 /tmp/boot_modified.wim
    printf "add /tmp/startnet.cmd /Windows/System32/startnet.cmd\nadd /tmp/winpeshl.ini /Windows/System32/winpeshl.ini\n" | \
        wimupdate /tmp/boot_modified.wim 2 >> "$LOG_FILE" 2>&1 || \
        handle_error "Failed to inject into boot.wim"
    cp /tmp/boot_modified.wim /mnt2/sources/boot.wim || handle_error "Failed to write modified boot.wim"
    rm -f /tmp/boot_modified.wim /tmp/startnet.cmd /tmp/winpeshl.ini
    log_success "Auto-bcdboot injected into WinPE image 2"
}

###########################################
# Step 9 : Install GRUB2 + wimboot
###########################################

step_install_grub() {
    log "=== Step 9/9 : Installing GRUB2 + wimboot ==="
    mountpoint -q /mnt || mount -t ntfs-3g "${DISK}1" /mnt || handle_error "Failed to mount ${DISK}1"
    mountpoint -q /mnt2 || mount -t ntfs-3g "${DISK}2" /mnt2 || handle_error "Failed to mount ${DISK}2"
    # Copy boot files to sda1 (persist after sda2 deletion)
    mkdir -p /mnt/Boot
    cp /mnt2/boot/boot.sdi /mnt/Boot/boot.sdi
    log "Downloading wimboot..."
    wget -q -O /mnt/Boot/wimboot "$WIMBOOT_URL" >> "$LOG_FILE" 2>&1 || handle_error "Failed to download wimboot"
    cp /mnt/Boot/wimboot /mnt2/boot/wimboot
    log_success "wimboot installed"
    # Install GRUB2 to MBR with boot directory on sda1 (survives sda2 deletion)
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
            log_success "GRUB2 installed on sda1"
            break
        fi
    done
    if [ "$grub_ok" = false ]; then
        handle_error "GRUB2 installation failed"
    fi
    # Single GRUB entry with auto-detection :
    # Boot/BCD present on sda1 -> boot installed Windows (normal boot after bcdboot ran)
    # Boot/BCD absent on sda1  -> boot WinPE from sda2 (first boot only, sda2 gets deleted after)
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
    log_success "GRUB2 configured on sda1 with auto-detect entry"
}

###########################################
# Final Verification
###########################################

step_finalize() {
    log "=== Final verification ==="
    mountpoint -q /mnt || mount -t ntfs-3g "${DISK}1" /mnt 2>/dev/null || true
    mountpoint -q /mnt2 || mount -t ntfs-3g "${DISK}2" /mnt2 2>/dev/null || true
    log "sda1 (Windows + GRUB) :"
    for f in "/mnt/Windows/System32/ntoskrnl.exe" "/mnt/Boot/wimboot" "/mnt/Boot/boot.sdi" "/mnt/boot/grub/grub.cfg"; do
        if [ -f "$f" ]; then
            log "  OK : $f"
        else
            log_warning "  MISSING : $f"
        fi
    done
    log "sda2 (Setup - auto-deleted on first boot) :"
    for f in "/mnt2/boot/wimboot" "/mnt2/bootmgr" "/mnt2/boot/bcd" "/mnt2/boot/boot.sdi" "/mnt2/sources/boot.wim"; do
        if [ -f "$f" ]; then
            log "  OK : $f"
        else
            log_warning "  MISSING : $f"
        fi
    done
    log "GRUB configuration :"
    cat /mnt/boot/grub/grub.cfg | while IFS= read -r line; do
        log "  $line"
    done
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
    echo -e "${BLUE}  MBR/Legacy BIOS - wimapply + wimboot               ${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo
    echo "=== Installation started at $(date) ===" >> "$LOG_FILE"
    mkdir -p "$BACKUP_DIR"
    step_check_system
    step_install_packages
    step_resolve_iso
    step_prepare_disk
    step_download_iso
    step_extract_iso
    step_apply_windows
    step_inject_bcdboot
    step_install_grub
    step_finalize
    echo
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}  Installation complete!                              ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo
    echo -e "${YELLOW}NEXT STEPS :${NC}"
    echo -e "${YELLOW}  1. Go to OVH Control Panel${NC}"
    echo -e "${YELLOW}  2. Change Netboot to 'Boot from hard disk'${NC}"
    echo -e "${YELLOW}  3. Reboot the server${NC}"
    echo
    echo -e "Full log : $LOG_FILE"
    echo
    echo -e "Press any key to reboot, Ctrl+C to cancel..."
    read -n 1 -s -r
    reboot
}

main
