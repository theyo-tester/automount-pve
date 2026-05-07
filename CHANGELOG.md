# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v2.3.0]

### Changed

- **configure_shares.sh** — completely rewrote the entire `configure_shares.sh`
  It was too complicated and convoluted and filled with "suggested" code to
  conform to "best practices".
  - CLI flags are gone.
  - Just two prompts, security posture and config overwrite.
  - Added some flags for Samba so it can be more MacOS friendly.
  - `ksmbd` is bad, don't use it, I don't support it anymore.
  - No more config merge. Just overwrite to output suggested settings for user.
- **Security Posture** — Shares are set up with simple choices.
  - **Open:** Good choice if you know your home network is secure.
  - **Limited:** Some safety measures to limit the scope of accepted connections.
  - **Secure:** Limit access to authenticated users and limit accepted connections.

## [v2.2.0]

### Added

- **NVMe USB enclosure support** — udev rules now match `nvme*n*p*` devices
  attached via USB (external NVMe enclosures). Internal NVMe drives are
  excluded by requiring `ID_BUS==usb` or `removable==1` with `SUBSYSTEMS=="usb"`.
- **Systemd journal integration** — `usb-mount@.service` now sets
  `StandardOutput=journal`, `StandardError=journal`, and
  `SyslogIdentifier=usb-mount@%i` so all mount/unmount output is captured by
  the journal. Query with `journalctl -u usb-mount@<device>`.
- **CLI flags for unattended configuration** — `configure_shares.sh` accepts
  `--smb`, `--nfs`, `--subnet`, `--guest-mode`, `--wide-links`,
  `--root-squash`, `--no-root-squash`, `--nfs-insecure` for scripted runs.
- **SMB security prompts** — interactive guest-access mode selection
  (guest / users / subnet), wide-links security warning, valid-users option.
- **NFS security prompts** — `root_squash` vs `no_root_squash` choice,
  insecure-port warning for non-standard NFS clients.
- **Config-merge strategy** — Samba and NFS configs use `# BEGIN/END
  automount-pve` markers for idempotent injection. Existing customisations
  outside the markers are preserved; conflicting directives inside the markers
  are commented with `# automount-pve-disabled:`.
- **Samba customisation detection** — `configure_shares.sh` runs `dpkg -V` to
  detect hand-edited `smb.conf` and warns before modifying it.
- **Backup before modification** — `configure_shares.sh` creates timestamped
  backups of `smb.conf` / `ksmbd.conf` / NFS exports before every edit.
- **SMB engine detection** — automatically chooses between `samba` (smbd) and
  `ksmbd` (in-kernel), with correct config path and reload command.
- `.gitattributes` enforcing LF line endings for `.sh`, `.rules`, `.service`.
- `CHANGELOG.md` (this file).

### Changed

- **udev rules** — partition pattern changed from `sd[a-z][0-9]` to
  `sd[a-z][0-9]*` so partitions 10+ are matched.
- **`mount_usb_memory.sh`** — uses `set -uo pipefail` (intentionally no `-e`).
  `do_unmount()` now uses `findmnt` instead of parsing `/proc/mounts`.
  `do_fsck()` rewritten to capture output with `$()` instead of
  fragile `cmd | while` + `PIPESTATUS` pipeline.
- **`add_rbind_mounts.sh`** — `read -rp` replaces `echo + read`; glob
  expansion quoted to silence SC2206.
- **`configure_shares.sh`** — substantially rewritten with safety
  guarantees (see Added above).

### Fixed

- `do_fsck()` NTFS / vfat / ext* pipelines now reliably capture the exit code
  regardless of subshell masking.
- Label sanitisation strips `/`, control characters, leading dots, and spaces
  to prevent path-traversal via crafted filesystem labels.
- `add_rbind_mounts.sh` temp file cleaned up via `trap cleanup EXIT`.

### Security

- SMB guest access is no longer silently enabled; the user must explicitly
  choose a guest mode and acknowledge the wide-links warning.
- NFS `no_root_squash` requires explicit opt-in with a clear warning about
  the privilege implications.
- Filesystem labels are sanitised to block path-traversal injection (e.g.
  `../../etc` on a crafted NTFS label).
