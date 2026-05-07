# Auto-Mount USB Storage on Proxmox

[![Proxmox](https://img.shields.io/badge/Platform-Proxmox-blue)](https://www.proxmox.com)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-lightgrey?logo=gnu-bash)](https://www.gnu.org/software/bash/)

Automount every partition (ext4 / NTFS / exFAT / FAT / XFS / btrfs) found on
dynamically-attached USB storage to `/mnt/<label>`. Supports both traditional
SCSI/SATA USB drives **and NVMe USB enclosures**. Optional NFS & SMB sharing
and recursive bind mounts for LXC containers.

Updated for **Proxmox 9** (Debian Trixie). Works on any systemd-based Debian 12+ or Ubuntu 22/24.

## Features

| Feature | Details |
| --- | --- |
| **Automatic mount/unmount** | udev rule triggers a systemd oneshot service on USB attach/detach |
| **NVMe USB enclosure support** | Matches `nvmeXnYpZ` devices connected via USB; internal NVMe drives are excluded |
| **Filesystem check on mount** | `ntfsfix`, `fsck.vfat`, `fsck.exfat`, `e2fsck`, `xfs_repair` run before every mount |
| **NTFS via ntfs-3g** | Prefers the `ntfs-3g` FUSE driver over the kernel `ntfs3` driver |
| **NFS & SMB sharing** | Interactive setup (`configure_shares.sh`) with security prompts, backups, and idempotent config merge |
| **LXC bind-mount fix** | `mnt-shared-propagation.service` + `add_rbind_mounts.sh` ensure USB sub-mounts are visible inside containers |
| **Journal logging** | Mount/unmount output goes to the systemd journal — `journalctl -u usb-mount@<device>` |
| **Safe installer** | Re-runnable; fixes broken symlinks, sets correct ownership/permissions |
| **Label sanitisation** | Filesystem labels are sanitised to prevent path-traversal injection |
| **ZFS unit fix** | Removes deprecated `Requires=systemd-udev-settle` from ZFS import units |

## Quick Start

```bash
curl -L https://github.com/theyo-tester/automount-pve/archive/refs/heads/main.tar.gz | tar xz -C /tmp/ && /tmp/automount-pve-main/installAutoMount.sh
```

The installer will:

1. Copy scripts to `/opt/automount-pve` and create symlinks in `/etc`.
2. Set correct ownership (`root:root`) and permissions (`0755` / `0644`).
3. Offer to install `ntfs-3g` and `exfatprogs` if missing.
   - Without `ntfs-3g` the kernel NTFS driver may mount read-only on dirty volumes.
   - Without `exfatprogs` file system checks for exFAT (and earlier varients) may not successfully run.
4. Install `mnt-shared-propagation.service` (mount propagation fix for LXC).
5. Override ZFS units if they depend on the deprecated `systemd-udev-settle`.
6. Prompt to configure NFS and/or SMB sharing of `/mnt`.

**Test:** Plug in a USB drive and check `/mnt` for a new directory.
 
## Filesystem Labels

Mount points are derived from filesystem labels.

| Device | Filesystem Label | Mountpoint |
| --- | --- | --- |
| `/dev/sda1` | `Entertainment` | `/mnt/Entertainment` |
| `/dev/nvme0n1p1` | `Backup` | `/mnt/Backup` |

- Malicious labels (e.g. `../../etc`) could attempt path-traversal. The mount script sanitises labels
by replacing `/` with `_`, stripping control characters, spaces and leading dots.
- If partition label does not exists, the device name (e.g. `sdc2`) is used. Duplicate labels get a device suffix.

## NVMe USB Enclosures
External NVMe enclosures (USB-to-NVMe adapters) expose devices as
`/dev/nvme0n1p1` instead of `/dev/sda1`. The udev rules match both patterns:

| Pattern | Example | Match |
| --- | --- | --- |
| `sd[a-z][0-9]*` | `/dev/sda1`, `/dev/sdc12` | Traditional SCSI/SATA USB drives |
| `nvme[0-9]*n[0-9]*p[0-9]*` | `/dev/nvme0n1p1` | NVMe-over-USB enclosures |

- Internal (non-USB) NVMe drives are excluded.
- The rules require either `ID_BUS==usb` (set by most USB-NVMe bridge chipsets) or both `removable==1` and `SUBSYSTEMS=="usb"`.
- If your NVMe enclosure is not detected, check `udevadm info /dev/nvme0n1p1 | grep ID_BUS` — if `ID_BUS` is not set to
`usb`, the secondary rule (`removable==1` + `SUBSYSTEMS=="usb"`) should still catch it. File an issue if neither works.


## NFS / Samba Sharing

`configure_shares.sh` prompts for a security posture:

- **Security Posture** — Shares are set up with simple choices.
  - **Open:** Good choice if you know your home network is secure.
  - **Limited:** Some safety measures to limit the scope of accepted connections.
  - **Secure:** Limit access to authenticated users and limit accepted connections.

- You can choose to overwrite your config or if you don't the config based on your
choices with be displayed at the command prompt for you to copy-paste (or ignore).
- `configure_shares.sh` creates timestamped backups of Samba/NFS configs
  before any modification.


## Journal Logging

All mount and unmount output is captured by the systemd journal:

```bash
# View logs for a specific device
journalctl -u usb-mount@sda1

# Follow in real-time
journalctl -fu usb-mount@sda1

# View NVMe mount logs
journalctl -u usb-mount@nvme0n1p1

# View all USB mount activity
journalctl -u 'usb-mount@*'
```

## LXC Container Visibility (Proxmox 9)

In Proxmox 9 I experienced an issue where USB volumes mounted under `/mnt` on
the host appear as **empty folders** inside LXC containers that bind-mount `/mnt`.

### The shared case scenario

The problem is **mount propagation**. When an LXC container starts, it gets a
snapshot of the current mount tree. USB drives mounted *after* the container
starts are not visible unless the mount point is marked **shared**.

This project installs `mnt-shared-propagation.service` which runs:

```bash
mount --make-rshared /mnt
```

In troubleshooting, Ai would always confidently proclaim this was the issue. As
I saw no issue with this simple step, I've included the fix to ensure
**this is never going to be the problem!**

### The recursive bind mount exception

USB drives mounted *before* the container can also experience a separate but similar
issue. This was my issue after upgrading to Proxmox 9. I don't think I had this
manifest as an issue in Proxmox 8.

The typical bind mount does not propagate sub-mounts into containers (e.g. if a USB
drive mounts at /mnt/usb, it won't appear inside the container).

```bash
mp0: /mnt,mp=/mnt
```

Instead, force a recursive bind mount:

```bash
lxc.mount.entry: /mnt mnt none rbind,create=dir 0 0
```

This makes the container's `/mnt` a direct view of the host's `/mnt` tree, and
with shared propagation, USB sub-mounts appear automatically.

## File Overview

| File | Purpose |
| --- | --- |
| `installAutoMount.sh` | Main installer — run this |
| `mount_usb_memory.sh` | Mount/unmount handler called by the systemd service |
| `configure_shares.sh` | Interactive NFS/SMB share setup for `/mnt` (with security prompts) |
| `add_rbind_mounts.sh` | Interactive configuration of LXC containers for recursive bind mounts |
| `99-auto-mount-sdxy.rules` | udev rules (SCSI/SATA + NVMe) that trigger `usb-mount@.service` |
| `usb-mount@.service` | systemd template unit (journal-integrated) |
| `mnt-shared-propagation.service` | Ensures `/mnt` has shared mount propagation for LXC |

## Troubleshooting

| Problem | Check |
| --- | --- |
| USB drive not detected | `udevadm monitor --udev` while plugging in; verify rules with `udevadm test /sys/block/sda/sda1` |
| NVMe enclosure not detected | `udevadm info /dev/nvme0n1p1 \| grep ID_BUS` — needs `usb` or `removable==1` |
| Mounts but empty in LXC | `findmnt -o TARGET,PROPAGATION /mnt` should show `shared`; ensure `rbind` not `bind` in container config |
| `ntfs-3g` not found | `apt install ntfs-3g` then re-plug the drive |
| Filesystem check fails | Check `journalctl -u usb-mount@<device>` for fsck output; may need manual `fsck` |
| SMB share not visible | Verify `smbd` is running; check `testparm` output |
| NFS export not visible | `exportfs -v` to confirm; ensure client matches the allowed subnet |
| Mount point collision | Two drives with the same label — second gets a `-<devname>` suffix automatically |

## Compatibility

| File | Item | PVE8 / Deb12 | PVE9 / Deb13 | Ubuntu 22/24 |
| --- | --- | --- | --- | --- |
| mount_usb_memory.sh | `findmnt` (util-linux) | ✓ | ✓ | ✓ |
| mount_usb_memory.sh | `/usr/sbin/blkid` | ✓ | ✓ | ✓ |
| mount_usb_memory.sh | `ntfs3` kernel driver | ✓ kernel 6.x | ✓ | ✓ kernel ≥5.15 |
| installAutoMount.sh | `dpkg -s` check | ✓ | ✓ | ✓ |
| installAutoMount.sh | `mountpoint -q` (util-linux) | ✓ | ✓ | ✓ |
| installAutoMount.sh | `exfatprogs` package | ✓ | ✓ | ✓ |
| mnt-shared-propagation.service | `Before=lxc.service pve-guests.service` | ✓ PVE units; ignored if absent | ✓ | ✓ (ignored) |
| 99-auto-mount-sdxy.rules | `sd[a-z][0-9]*` + `nvme*` | ✓ | ✓ | ✓ |
| All scripts | `#!/bin/bash` + `[[ ]]`, `${BASH_SOURCE[0]}` | ✓ bash ≥4.2 | ✓ | ✓ |
