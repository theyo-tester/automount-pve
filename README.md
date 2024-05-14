# Auto-Mount Memories on Proxmox (8) or any Debian (12) based system
This is a set of auto-mount script & rules tested on Proxmox 8. It will  mount every partition (ext4/ntfs/fat) found on dynamically/usb attached memories (sticks, external HDDs, sd-cards...) to /mnt/auto/....

## Why?
- Let's assume, you just want to transfer some files offline to/from a usb attached memory, you would need to execute the same (rather simple) commands every time you attach the disk again. This is annoying!
- As long as you use the same partition label, you can statically create a directory storage in the pve GUI, and use it as backup location f.i.. As soon the memory containing the partition is attached, it can be used by PVE for backups.
- I found no final solution for this task (especially for pve 8 on debian 12). Other found solutions are not mantained anymore. I did not even tried them because they were made for pve7
- That's why I wrote my own solution after some try and fails.
# Install
- Clone/Download this repo to your machine. Go inside the folder.
- run `./installAutoMount.sh`   This will copy the needed files to the right folders and reload systemd.
- *!!* make sure you also install the 'ntfs-3g' package, if you will mount ntfs drives. Otherwise your drive will be mounted read-only without any warning! 
- Test: Plug in a usb memory and check the /mnt/auto folder for further subdirectories. /mnt/auto will be automatically, created as soon some partition can be mounted there.

## Important notes
- systemd-udev-settle is deprecated and it breaks the whole booting process. Even Networking is stopped at boot after just a simple harmless udev rule is added.
- This script will override two pve default services (if found), which are unnecessarily using systemd-udev-settle: zfs-import-cache and zfs-import-scan. The small change will take out the dependency for systemd-udev-settle. **But there is a catch:**
- **!!** If this default unit files will change in future updates, these overrides will not be aware of that. I saw no other option to take out the broken dependency. If anyone knows a better option, feel free to suggest! But there is good news also:
- The install script will only apply the overrides, if a dependency to systemd-udev-settle will be found. If they fix this in the future, the override will not be applied anymore (at install!).
- **!!** This automation was only **tested on Proxmox 8 with LVM storage** (no ZFS). If you are using zfs, use it at your own risk! Any feedback is appreciated. Otherwise, I plan to test this myself in the future.
- The mount folder name will be  the label of the partition, by default. If no label can be determined, the name of the device (e.g sdc2) will be used. If a directory with the same name exists already, then the folder will get the device name as suffix.
- If you are using ntfs drives, make sure to install  the 'ntfs-3g' package, otherwise your it will be mounted in read-only mode without any warning!

Example:
Partition /dev/sdb1
Partition Label: myUsbData
==> Mount will be found at /mnt/auto/myUsbData
- This automation will **NOT** create a new storage in PVE. For this you have to go in the pve gui:
  - Datacenter->Storage->Add->Directory
  - Specify any ID you want (I usually specify the partition label here but it doesn't matter)
  - Directory: the automatically created mountpoint, e.g. /mnt/auto/myUsbData[/optionalSubfolder]  I suggest you create a special folder on your storage (f.i. "pve")  for proxmox related data
  - Content: choose also **VZDump** if you want to save pve **backups** on it.
- The main mount script (mount_usb_memory.sh) was inspired from [this article](https://andreafortuna.org/2019/06/26/automount-usb-devices-on-linux-using-udev-and-systemd/)

## To Do
- At instalation, offer option to install the ntfs-3g package, if not found.

