#!/bin/bash

###########################################
#  Windows ISO Installation               #
#  OVH Dedicated Server - MBR/Legacy      #
###########################################

# v3.3

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
# ACCOUNT MODEL :
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
# the process dies with a half-written disk. The script offers to relaunch
# itself inside tmux when you are not in a multiplexer.
# NEVER launch it with '&' or nohup : it is an interactive wizard, and a
# background job is stopped by the kernel the moment it asks a question.

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
UNATTEND_PRODUCT_KEY=""
DRIVERS_DIR=""
DRIVERS_INF_COUNT=0
INJECT_DRIVERS_IN_WINPE=false
CHOICE_INDEX=-1
LETTERS="abcdefghijklmnopqrstuvwxyz"
# Several file hosts serve an error page to the default wget/curl agent
HTTP_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

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

# Saved before the parsing loop consumes them : used to re-exec the script
# inside tmux with the exact same arguments.
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
ORIGINAL_ARGS=("$@")

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

cleanup_wizard_mounts() {
    # Loop mounts left behind by an aborted run keep the ISO file busy and make
    # the next run behave differently (wrong /tmp free space, stale mount).
    mountpoint -q "$WIZARD_ISO_MOUNT" 2>/dev/null && umount -f "$WIZARD_ISO_MOUNT" 2>/dev/null || true
    mountpoint -q /root/iso_check 2>/dev/null && umount -f /root/iso_check 2>/dev/null || true
    rm -rf /root/iso_check 2>/dev/null || true
}

on_exit() {
    local rc=$?
    cleanup_wizard_mounts
    exit "$rc"
}
trap on_exit EXIT

###########################################
# Interactive input helpers
#
# Every prompt reads from the controlling terminal (/dev/tty) rather than stdin,
# so a redirected or exhausted stdin cannot silently abort the wizard (with
# "set -e", a failing "read" exits the script without a word).
# A background launch ("bash script &", nohup, ...) is also detected : without
# this, the first prompt raises SIGTTIN, the script is Stopped, and everything
# typed afterwards lands in the parent shell ("-bash: y: command not found").
###########################################

REPLY_LINE=""

terminal_is_ours() {
    # True when this process group owns the terminal (i.e. runs in foreground).
    # If ps cannot tell us, assume foreground rather than waiting forever.
    local pgid tpgid
    pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    tpgid=$(ps -o tpgid= -p $$ 2>/dev/null | tr -d ' ')
    [ -z "$pgid" ] || [ -z "$tpgid" ] || [ "$pgid" = "$tpgid" ]
}

ensure_terminal_ready() {
    if ! { true >/dev/tty; } 2>/dev/null; then
        log_error "No controlling terminal, but this script is an interactive wizard."
        log_error "Run it directly in an SSH session (ideally inside tmux) - not via nohup, cron or a pipe."
        exit 1
    fi
    local warned=false
    while ! terminal_is_ours; do
        if [ "$warned" = false ]; then
            warned=true
            {
                echo
                echo -e "${RED}This script runs in the BACKGROUND but needs keyboard input.${NC}"
                echo -e "${YELLOW}Most likely cause : an UNQUOTED ISO URL. Every '&' in it started a${NC}"
                echo -e "${YELLOW}background job and the URL was cut at the first '&'. In that case do${NC}"
                echo -e "${YELLOW}NOT resume : kill this job and relaunch with the URL in single quotes :${NC}"
                echo -e "${YELLOW}    bash '$SCRIPT_PATH' 'https://host/path?id=...&confirm=...'${NC}"
                echo
                echo -e "${YELLOW}Otherwise, type  fg  in this shell to bring it back (waiting...).${NC}"
                echo -e "${YELLOW}Reminder : '&' does NOT protect the install from an SSH drop - tmux does.${NC}"
            } >/dev/tty
        fi
        sleep 2
    done
}

read_line() {
    ensure_terminal_ready
    REPLY_LINE=""
    if ! IFS= read -r REPLY_LINE </dev/tty; then
        echo
        handle_error "Terminal input closed unexpectedly (EOF)"
    fi
    # A trailing CR can survive a paste from a Windows client and would silently
    # corrupt a URL, a computer name or a product key
    REPLY_LINE="${REPLY_LINE%$'\r'}"
}

read_secret() {
    ensure_terminal_ready
    REPLY_LINE=""
    if ! IFS= read -rs REPLY_LINE </dev/tty; then
        echo
        handle_error "Terminal input closed unexpectedly (EOF)"
    fi
    echo
}

relaunch_in_multiplexer() {
    # Re-exec this script (same arguments) inside a fresh tmux session
    local cmd sess n
    if ! command -v tmux >/dev/null 2>&1; then
        log "Installing tmux..."
        apt-get update >> "$LOG_FILE" 2>&1 || true
        apt-get install -y tmux >> "$LOG_FILE" 2>&1 || true
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        log_error "tmux could not be installed. Answer y to continue without it, or install screen manually."
        return 1
    fi
    cmd=$(printf '%q ' bash "$SCRIPT_PATH" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"})
    sess="winsetup"
    n=1
    while tmux has-session -t "$sess" 2>/dev/null; do
        sess="winsetup${n}"
        n=$((n + 1))
    done
    log "Relaunching inside tmux session '$sess'"
    log "Detach : Ctrl+B then D  |  Reattach : tmux attach -t $sess"
    sleep 3
    exec tmux new -s "$sess" "$cmd"
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

to_crlf() {
    # Every file this script drops on a Windows/WinPE volume goes through here.
    # cmd.exe needs CRLF : with LF-only endings, "goto <label>" fails with "The
    # system cannot find the batch label specified" and parenthesised blocks are
    # mis-parsed - both would only show up on a headless first boot.
    sed -i 's/\r*$/\r/' "$1"
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
        read_line
        local ans
        ans=$(echo "$REPLY_LINE" | tr '[:upper:]' '[:lower:]')
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

normalize_download_url() {
    # Google Drive links exist in a dozen shapes but only the file id matters.
    # Rebuilding the canonical direct-download URL repairs a share link
    # (/file/d/<id>/view) and, above all, a Drive link truncated at the first '&'
    # by an unquoted command line - the id always comes before it.
    # A link that already carries "export=download" is left untouched : its
    # at=/uuid= tokens are what authorize a non-public file, dropping them would
    # turn a working URL into a login redirect.
    local url="$1"
    local id=""
    local re_id='[?&]id=([A-Za-z0-9_-]{10,})'
    local re_path='/d/([A-Za-z0-9_-]{10,})'
    case "$url" in
        *drive.google.com*|*drive.usercontent.google.com*|*docs.google.com*) ;;
        *) echo "$url"; return 0 ;;
    esac
    case "$url" in
        *export=download*) echo "$url"; return 0 ;;
    esac
    if [[ "$url" =~ $re_id ]]; then
        id="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ $re_path ]]; then
        id="${BASH_REMATCH[1]}"
    fi
    if [ -n "$id" ]; then
        echo "https://drive.usercontent.google.com/download?id=${id}&export=download&confirm=t"
        return 0
    fi
    echo "$url"
}

URL_CHECK_DIAG=""

check_download_url() {
    # Returns non-zero when the URL serves a web page (login form, anti-bot
    # challenge, error page) instead of a file. Catching this here avoids
    # downloading several GB of HTML and failing much later on ISO verification.
    local url="$1"
    URL_CHECK_DIAG=""
    local out info code ctype eff
    local fmt='__CURLINFO__|%{http_code}|%{content_type}|%{url_effective}\n'
    out=$(curl -sIL -A "$HTTP_UA" -m 45 -w "$fmt" "$url" 2>/dev/null || true)
    info=$(echo "$out" | grep '^__CURLINFO__' | tail -1 || true)
    code=$(echo "$info" | cut -d'|' -f2)
    # Many hosts refuse or mishandle HEAD : retry with a 1-byte ranged GET.
    # The timeout caps the damage if the server ignores the Range header.
    if [[ ! "$code" =~ ^2 ]]; then
        local out_get info_get
        out_get=$(curl -sL -A "$HTTP_UA" -m 45 -r 0-0 -D - -o /dev/null -w "$fmt" "$url" 2>/dev/null || true)
        info_get=$(echo "$out_get" | grep '^__CURLINFO__' | tail -1 || true)
        if [ -n "$info_get" ]; then
            out="$out_get"
            info="$info_get"
            code=$(echo "$info" | cut -d'|' -f2)
        fi
    fi
    if [ -z "$info" ]; then
        URL_CHECK_DIAG="No HTTP response (dead link, DNS or network problem)"
        return 1
    fi
    ctype=$(echo "$info" | cut -d'|' -f3)
    eff=$(echo "$info" | cut -d'|' -f4)
    case "$eff" in
        *accounts.google.com*|*ServiceLogin*|*/signin*)
            URL_CHECK_DIAG="Google redirects to a login page : file not shared publicly, or its at=/uuid= tokens are expired or refused from this server IP"
            return 1
            ;;
    esac
    if echo "$out" | grep -qi '^cf-mitigated:'; then
        URL_CHECK_DIAG="Blocked by a Cloudflare anti-bot challenge : only a real browser can pass"
        return 1
    fi
    case "$ctype" in
        text/html*|application/xhtml*)
            URL_CHECK_DIAG="The server returns a web page (HTTP ${code:-?}), not a file"
            # Read the page title : Drive states its refusal there
            # ("Quota exceeded", "Access denied"...), which is far more useful
            # than a generic "not a file" message.
            local title
            # No Range here : some hosts answer a ranged request with raw file
            # bytes instead of the page. --max-filesize keeps this bounded.
            title=$(curl -sL -A "$HTTP_UA" -m 20 --max-filesize 2000000 "$url" 2>/dev/null | tr -d '\r\n' | grep -io '<title>[^<]*' | head -1 | cut -c8- || true)
            [ -n "$title" ] && URL_CHECK_DIAG="$URL_CHECK_DIAG - the page says : \"$title\""
            return 1
            ;;
    esac
    if [ "$code" = "000" ]; then
        URL_CHECK_DIAG="No response from the server (DNS, TLS or network problem)"
        return 1
    fi
    if [[ ! "$code" =~ ^2 ]]; then
        URL_CHECK_DIAG="HTTP $code returned by the server"
        return 1
    fi
    return 0
}

explain_bad_url() {
    log_error "$URL_CHECK_DIAG"
    echo
    echo -e "${YELLOW}  This link cannot be fetched from a server (no browser here).${NC}"
    echo -e "  ${BLUE}Google Drive${NC} : share the file as 'Anyone with the link', then use"
    echo -e "                 https://drive.usercontent.google.com/download?id=<FILE_ID>&export=download&confirm=t"
    echo -e "                 (a private file works in your browser thanks to your session,"
    echo -e "                  and Drive often refuses datacenter IPs like this server)"
    echo -e "  ${BLUE}Drive 'Quota exceeded'${NC} : per-file download cap, reset can take up to 24h."
    echo -e "                 Make a COPY of the file in your own Drive : the copy gets a new"
    echo -e "                 file id, hence a fresh quota. Or use the scp route below."
    echo -e "  ${BLUE}Cloudflare / anti-bot${NC} : host the ISO elsewhere, or copy it yourself :"
    echo -e "                 scp your.iso root@<this_server>:/tmp/   then relaunch with NO url argument"
    echo -e "  ${BLUE}Tip${NC} : pasting the URL at this prompt needs no quotes, unlike the command line."
    echo
}

get_remote_size() {
    # Prints the remote file size in bytes, or 0 if unknown
    local url="$1"
    local size
    size=$(curl -sLI -A "$HTTP_UA" "$url" | grep -i "Content-Length" | tail -1 | awk '{print $2}' | tr -d '\r' || echo 0)
    if ! [ "$size" -gt 0 ] 2>/dev/null; then
        # HEAD blocked : 1-byte range GET returns Content-Range with total size
        size=$(curl -sL -A "$HTTP_UA" -r 0-0 -D - -o /dev/null "$url" | grep -i "Content-Range" | grep -oP '/\K[0-9]+' || echo 0)
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
        log_warning "Backgrounding it with '&' does NOT help : the wizard needs the keyboard."
        while true; do
            echo -ne "${YELLOW}[t] relaunch inside tmux (recommended) | [y] continue anyway | [n] abort (Enter) : ${NC}"
            read_line
            local tmux_answer
            tmux_answer=$(echo "$REPLY_LINE" | tr '[:upper:]' '[:lower:]')
            case "$tmux_answer" in
                t) relaunch_in_multiplexer || true ;;
                y) break ;;
                n|"")
                    echo -e "${GREEN}Good call. Run : tmux new -s win  (then relaunch this script)${NC}"
                    exit 0
                    ;;
                *) echo -e "${RED}  Pick t, y or n.${NC}" ;;
            esac
        done
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
        "libxml2-utils"
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
    local skipped=0
    # The OVH rescue system exposes 16 empty nbd* devices (plus loop/ram/zram
    # ones) that lsblk reports as type "disk". Keep only real, non-empty media.
    while read -r name size model; do
        case "$name" in
            nbd*|loop*|ram*|zram*|sr*|fd*|dm-*|md*)
                skipped=$((skipped + 1))
                continue
                ;;
        esac
        local dev="/dev/${name}"
        local bytes
        bytes=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        if [ "${bytes:-0}" -le 0 ]; then
            skipped=$((skipped + 1))
            continue
        fi
        candidates+=("$dev")
        if [ -n "${model// /}" ]; then
            names+=("${dev}  (${size})  ${model}")
        else
            names+=("${dev}  (${size})")
        fi
    done < <(lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk" {name=$1; size=$2; $1=""; $2=""; $3=""; sub(/^[[:space:]]+/, ""); print name" "size" "$0}')
    [ "$skipped" -gt 0 ] && log "Ignored $skipped empty or virtual device(s) (nbd, loop, ram...)"
    if [ "${#candidates[@]}" -eq 0 ]; then
        handle_error "No usable physical disk found (empty and virtual devices are ignored)"
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
        local reused=false
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
                echo -e "${BLUE}  Paste the URL as-is : no quotes needed here, unlike the command line.${NC}"
                echo -ne "${YELLOW}Windows ISO download URL : ${NC}"
                read_line
                WINDOWS_ISO_URL="$REPLY_LINE"
                [ -z "$WINDOWS_ISO_URL" ] && { log_warning "Empty URL"; continue; }
                from_url=true
            fi
        fi
        if [ "$from_url" = true ]; then
            # Rebuild Drive links from their file id (also repairs a link cut at
            # the first '&' by an unquoted command line)
            local normalized
            normalized=$(normalize_download_url "$WINDOWS_ISO_URL")
            if [ "$normalized" != "$WINDOWS_ISO_URL" ]; then
                WINDOWS_ISO_URL="$normalized"
                log "Google Drive link rebuilt : $WINDOWS_ISO_URL"
            fi
            # Reject login pages / anti-bot challenges before downloading GBs
            log "Checking the link..."
            if ! check_download_url "$WINDOWS_ISO_URL"; then
                explain_bad_url
                WINDOWS_ISO_URL=""
                continue
            fi
            local remote_size
            remote_size=$(get_remote_size "$WINDOWS_ISO_URL")
            # Resolve the /tmp target name FIRST : an aborted run may already have
            # downloaded this ISO. That leftover file still occupies RAM-backed
            # /tmp, so ignoring it made a relaunch wrongly conclude "too large for
            # /tmp" and silently fall back to deferred mode.
            local iso_filename
            iso_filename=$(curl -sL -A "$HTTP_UA" -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" 2>/dev/null | grep -i "Content-Disposition" | grep -oP 'filename="\K[^"]+' || true)
            [ -z "$iso_filename" ] && iso_filename="win.iso"
            iso_filename="${iso_filename// /_}"
            local tmp_target="/tmp/${iso_filename}"
            local existing_size=0
            [ -f "$tmp_target" ] && existing_size=$(stat -c%s "$tmp_target" 2>/dev/null || echo 0)
            local tmp_free
            tmp_free=$(get_tmp_free_bytes)
            # Space available once the leftover file is replaced
            local tmp_free_effective=$((tmp_free + existing_size))
            local margin=$((2 * 1024 * 1024 * 1024))
            if [ "$remote_size" -gt 0 ]; then
                SETUP_SIZE_GIB=$((remote_size / 1024 / 1024 / 1024 + 2))
                log "Remote ISO size : $((remote_size / 1024 / 1024)) MB"
            else
                SETUP_SIZE_GIB=25
                log_warning "Could not determine ISO size, using default ${SETUP_SIZE_GIB} GiB setup partition"
            fi
            # Reuse a complete download left by a previous run instead of pulling
            # several GB again (and instead of keeping two copies in RAM)
            if [ "$existing_size" -gt 0 ] && { [ "$remote_size" -eq 0 ] || [ "$existing_size" -eq "$remote_size" ]; }; then
                log "Previous download found : $tmp_target ($((existing_size / 1024 / 1024)) MB), verifying..."
                if verify_iso "$tmp_target"; then
                    ISO_PATH="$tmp_target"
                    USE_LOCAL_ISO=true
                    reused=true
                    log_success "Reusing the already downloaded ISO (no re-download)"
                else
                    log_warning "Previous download is unusable, it will be replaced"
                fi
            fi
            if [ "$reused" = false ]; then
                if [ "$remote_size" -gt 0 ] && [ "$tmp_free_effective" -gt $((remote_size + margin)) ]; then
                    # Enough space in /tmp (RAM-backed) : download NOW so the wizard
                    # can offer edition/language selection before anything destructive
                    log "Downloading ISO to /tmp (fits in RAM-backed storage)..."
                    ISO_PATH="$tmp_target"
                    rm -f "$ISO_PATH"
                    if ! wget --progress=bar:force --user-agent="$HTTP_UA" -O "$ISO_PATH" "$WINDOWS_ISO_URL" 2>&1; then
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
        fi
        # Verify integrity before letting the user configure anything
        if [ "$reused" = false ]; then
            log "Verifying ISO integrity..."
            if ! verify_iso "$ISO_PATH"; then
                log_error "ISO is corrupted, truncated or not a Windows ISO : $ISO_PATH"
                ISO_PATH=""
                WINDOWS_ISO_URL=""
                USE_LOCAL_ISO=false
                continue
            fi
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
            read_line
            local manual_code="$REPLY_LINE"
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
            read_line
            UNATTEND_TIMEZONE="$REPLY_LINE"
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
    read_line
    local comp_name="$REPLY_LINE"
    [ -z "$comp_name" ] && comp_name="$UNATTEND_COMPUTER_NAME"
    # Max 15 chars, alphanumeric and hyphens only
    comp_name=$(echo "$comp_name" | tr -cd 'A-Za-z0-9-' | head -c 15)
    [ -z "$comp_name" ] && comp_name="WIN-OVH"
    UNATTEND_COMPUTER_NAME="$comp_name"
    log "Computer name : $UNATTEND_COMPUTER_NAME"
}

wizard_set_product_key() {
    # setup.exe is never executed by this script, so the windowsPE pass - the one
    # that normally consumes the product key - never runs. On a VL image without
    # an embedded PID, OOBE then stops at "It's time to enter the product key",
    # which needs a KVM on a headless server. Declaring the key in the specialize
    # pass is what actually skips that screen.
    echo
    echo -e "${BLUE}── Product key ──${NC}"
    echo -e "  ${YELLOW}Without a key, first boot may stop at the OOBE product key screen${NC}"
    echo -e "  ${YELLOW}and wait for a human : a blocker on a headless server.${NC}"
    echo -e "  Use your own key, or the KMS client setup key (GVLK) Microsoft"
    echo -e "  publishes for your edition."
    while true; do
        echo -ne "  Product key [Enter = none] : "
        read_line
        local key
        key=$(echo "$REPLY_LINE" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
        if [ -z "$key" ]; then
            UNATTEND_PRODUCT_KEY=""
            log_warning "No product key : first boot may stop at the OOBE key screen"
            return 0
        fi
        if echo "$key" | grep -qE '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$'; then
            UNATTEND_PRODUCT_KEY="$key"
            log "Product key : provided"
            return 0
        fi
        echo -e "${RED}  Invalid format (expected XXXXX-XXXXX-XXXXX-XXXXX-XXXXX).${NC}"
    done
}

wizard_set_account() {
    # Unified for all editions : a named local admin account is always created.
    # On Server, its password is also mirrored to the built-in Administrator.
    echo
    echo -e "${BLUE}── Administrator account ──${NC}"
    echo -e "  ${YELLOW}This account is added to the Administrators group and used for RDP.${NC}"
    while true; do
        echo -ne "  Username to create : "
        read_line
        local input_username
        input_username=$(echo "$REPLY_LINE" | tr -cd 'A-Za-z0-9_-' | head -c 20)
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
        read_secret
        local input_password="$REPLY_LINE"
        REPLY_LINE=""
        if [ ${#input_password} -lt 8 ]; then
            echo -e "${RED}  Password too short (minimum 8 characters).${NC}"
            continue
        fi
        echo -ne "  Confirm password : "
        read_secret
        local confirm_password="$REPLY_LINE"
        REPLY_LINE=""
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
        read_line
        local drv_url="$REPLY_LINE"
        [ -z "$drv_url" ] && { echo -e "${RED}  Empty URL.${NC}"; continue; }
        rm -rf /tmp/driverpack /tmp/driverpack_archive
        mkdir -p /tmp/driverpack
        if ! wget -q --user-agent="$HTTP_UA" -O /tmp/driverpack_archive "$drv_url"; then
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

# Final destructive gate : explicit, disk named, single word to type.
# Returns 0 only when the user typed ERASE exactly ; any other answer (including
# a bare Enter, which is easy to hit by accident) goes back to the summary.
confirm_erase() {
    echo
    echo -e "${RED}LAST CHANCE : ${DISK_LABEL} will be COMPLETELY ERASED.${NC}"
    echo -ne "${YELLOW}Type ERASE to proceed (Enter or anything else = back to summary) : ${NC}"
    read_line
    if [ "$REPLY_LINE" = "ERASE" ]; then
        return 0
    fi
    echo -e "${YELLOW}Not confirmed : back to the summary. Nothing was written to disk.${NC}"
    echo -e "${YELLOW}(use q on the summary screen to quit)${NC}"
    return 1
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
    wizard_set_product_key
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
        local key_line="none (OOBE may ask for it on first boot)"
        [ -n "$UNATTEND_PRODUCT_KEY" ] && key_line="$UNATTEND_PRODUCT_KEY"
        echo -e "${GREEN}10)${NC} Product key   : $key_line"
        echo -e "    RDP           : enabled, port 3389, firewall open"
        echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}"
        echo
        echo -ne "${YELLOW}Enter = confirm and install | 1-10 = edit item | q = quit : ${NC}"
        read_line
        local summary_choice
        summary_choice=$(echo "$REPLY_LINE" | tr '[:upper:]' '[:lower:]')
        case "$summary_choice" in
            ""|y)
                # The ERASE gate is part of the loop : failing it returns here
                # instead of throwing away the whole configuration.
                if confirm_erase; then
                    break
                fi
                ;;
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
            10) wizard_set_product_key ;;
            *) echo -e "${RED}Invalid choice.${NC}" ;;
        esac
    done
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
    # A huge ISO on a small disk would leave Windows almost no room (or a
    # negative size, which parted would happily turn into a mess)
    if [ "$win_end_mib" -lt 25600 ]; then
        handle_error "Windows partition would be only ${win_end_mib} MiB (setup partition needs ${setup_mib} MiB for the ISO). Use a bigger disk or a smaller ISO."
    fi
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
        local normalized
        normalized=$(normalize_download_url "$WINDOWS_ISO_URL")
        if [ "$normalized" != "$WINDOWS_ISO_URL" ]; then
            WINDOWS_ISO_URL="$normalized"
            log "Google Drive link rebuilt : $WINDOWS_ISO_URL"
        fi
        if ! check_download_url "$WINDOWS_ISO_URL"; then
            explain_bad_url
            echo -ne "${YELLOW}New ISO URL (or Ctrl+C to abort) : ${NC}"
            read_line
            WINDOWS_ISO_URL="$REPLY_LINE"
            continue
        fi
        local iso_filename
        iso_filename=$(curl -sL -A "$HTTP_UA" -r 0-0 -D - -o /dev/null "$WINDOWS_ISO_URL" 2>/dev/null | grep -i "Content-Disposition" | grep -oP 'filename="\K[^"]+' || true)
        [ -z "$iso_filename" ] && iso_filename="win.iso"
        iso_filename="${iso_filename// /_}"
        ISO_PATH="/mnt/${iso_filename}"
        rm -f "$ISO_PATH"
        if ! wget --progress=bar:force --user-agent="$HTTP_UA" -O "$ISO_PATH" "$WINDOWS_ISO_URL" 2>&1; then
            log_error "Download failed"
            rm -f "$ISO_PATH"
            echo -ne "${YELLOW}New ISO URL (or Ctrl+C to abort) : ${NC}"
            read_line
            WINDOWS_ISO_URL="$REPLY_LINE"
            continue
        fi
        log "Verifying downloaded ISO..."
        if ! verify_iso "$ISO_PATH"; then
            log_error "Downloaded ISO is corrupted or not a Windows ISO"
            rm -f "$ISO_PATH"
            echo -ne "${YELLOW}New ISO URL (or Ctrl+C to abort) : ${NC}"
            read_line
            WINDOWS_ISO_URL="$REPLY_LINE"
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
    # Deferred mode downloads the ISO onto the Windows partition : its content is
    # now on the setup partition, so drop it instead of leaving several GB of
    # dead weight on C: forever.
    if echo "$ISO_PATH" | grep -q "^/mnt/"; then
        log "Remov
