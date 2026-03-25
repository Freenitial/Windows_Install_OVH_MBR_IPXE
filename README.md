# Windows setup on OVH Dedicated Server (MBR/Legacy BIOS)

Bash script that installs Windows on an OVH dedicated server booted in rescue mode (Legacy BIOS only).

Tested on KIMSUFI KS-C using Windows Server 2025 ISO. 

## ⚠️ WARNING

**This script will completely wipe the target disk.** All existing data, partitions, and operating systems will be destroyed. 

Make sure you have backups of anything you care about before running this.

BE CAREFUL with Windows 11 because of TPM, you may need to patch your ISO first. Not tested. 

(Windows Server 2025 allow Legacy BIOS)

## How it works

1. Partitions the disk (sda1 = Windows, sda2 = temporary setup)
2. Applies the Windows image directly from Linux using `wimapply`
3. Injects an automatic `bcdboot` script into WinPE
4. Sets up GRUB2 + wimboot as the bootloader
5. **First reboot** : WinPE creates boot files, deletes sda2, extends sda1, reboots automatically
6. **Second reboot** : Windows OOBE starts (language, admin password, etc.)

No manual intervention between the two reboots.

## Requirements

- OVH dedicated server booted in **rescue DEBIAN** (Linux)
- **Legacy BIOS** (MBR) - not UEFI
- A Windows Server ISO (URL or local file)

## Usage

### 1. Boot into rescue mode

In OVH Control Panel, set Netboot to **rescue (DEBIAN)** and reboot the server.

### 2. Copy the script to the server

From your local machine (PowerShell, Terminal, etc.) :
```
scp install_windows_ovh_mbr.sh root@YOUR_SERVER_IP:/root/
```

If SSH warns about a changed host key (common after reboot in rescue mode), run `ssh-keygen -R YOUR_SERVER_IP` to clear the old key and try again.

### 3. Connect via SSH
```
ssh root@YOUR_SERVER_IP
```

### 4. Run the script
```bash
# Interactive (prompts for ISO source)
bash /root/install_windows_ovh_mbr.sh

# Or pass the ISO URL directly
bash /root/install_windows_ovh_mbr.sh "https://example.com/windows.iso"
```

The script will detect any local `.iso` files and let you pick one, or you can enter a download URL.

### 5. After the script completes, __BEFORE REBOOT__

1. Go to **OVH Control Panel**
2. Change Netboot to **Boot from hard disk**
3. **Reboot**
4. Wait and enjoy
