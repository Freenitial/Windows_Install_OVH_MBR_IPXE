# Windows setup on OVH Dedicated Server (MBR/Legacy BIOS)

Bash script that installs Windows on an OVH dedicated server booted in rescue mode - **LEGACY BIOS ONLY**.

Tested on KIMSUFI KS-C using Windows Server 2025 ISO.

## ⚠️ WARNING

**This script will completely wipe the target disk.** All existing data, partitions, and operating systems will be destroyed.

Make sure you have backups of anything you care about before running this.

## How it works

1. Asks for all configuration up front (disk, ISO, edition, language, keyboard, time zone, account, drivers), then a confirmation before anything is written
2. Partitions the disk (first partition = Windows, second = temporary setup files)
3. Applies the Windows image directly from Linux using `wimapply`
4. Injects an automatic driver + `bcdboot` script into WinPE
5. Sets up GRUB2 + wimboot as the bootloader
6. **First reboot** : WinPE injects drivers, creates boot files, deletes the setup partition, extends the Windows partition, reboots automatically
7. **Second reboot** : Windows finishes setup unattended (OOBE skipped) and comes up with RDP enabled

No manual intervention between the two reboots. Connect via RDP with the account set during configuration.

## Requirements

- OVH dedicated server booted in **rescue DEBIAN** (Linux)
- **Legacy BIOS** (MBR) - not UEFI
- A Windows ISO — client (Windows 10/11) or Server (URL or local file)

Both SATA/SAS (`/dev/sdX`) and NVMe (`/dev/nvmeXnY`) disks are supported. On a multi-disk server the script asks which disk to install to; the others are left untouched.

## Drivers (optional)

If your server has hardware without a Windows inbox driver (some NICs or storage controllers), extract the vendor driver pack — it must contain `.inf` files, not a `setup.exe` — into `/root/drivers` before running, or provide a `.zip` / `.tar.gz` URL when prompted. The script lists the detected network and storage hardware to help you decide.

## Usage

### 1. Boot into rescue mode

In OVH Control Panel, **disable monitoring (interventions)**, set Netboot to **rescue (DEBIAN)** and reboot the server.

### 2. Copy from your local machine to the server

Copy the script :
```
scp install_windows_ovh_mbr.sh root@YOUR_SERVER_IP:/root/
```

(RECOMMENDED) Copy your ISO :
```
scp "Path\To\Windows.iso" root@YOUR_SERVER_IP:/tmp/
```

If SSH warns about a changed host key (common after reboot in rescue mode), run `ssh-keygen -R YOUR_SERVER_IP` to clear the old key and try again.

### 3. Connect via SSH
```
ssh root@YOUR_SERVER_IP
```

Running inside `tmux` or `screen` is recommended, so the install survives a dropped SSH session.

### 4. Run the script
```bash
# Interactive configuration wizard
bash /root/install_windows_ovh_mbr.sh

# Or pass the ISO URL directly
bash /root/install_windows_ovh_mbr.sh "https://example.com/windows.iso"
```

The script detects any local `.iso` files and lets you pick one, or you can enter a download URL.

### 5. After the script completes, __BEFORE REBOOT__

1. Go to **OVH Control Panel**
2. Change Netboot to **Boot from hard disk**
3. **Reboot**

The server then reboots automatically twice (WinPE finalizes the boot files, then Windows completes setup) — allow ~5-15 minutes. 

Once it is up, connect via RDP using the account set during configuration.


