#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# installUSBAutoMount.sh
# installer for Proxmox 9 (Debian Trixie) USB automount system.
#
# Repo: https://github.com/theyo-tester/automount-pve
# Safe to re-run on a broken or partially broken install — removes stale
# symlinks and files before recreating them, sets correct ownership &
# permissions, and offers to install required packages.
#
# Also handles the deprecated systemd-udev-settle dependency in ZFS units
# and sets up mount propagation so LXC containers can see USB volumes.
# ---------------------------------------------------------------------------

OPT_DIR=/opt/automount-pve
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colours for terminal output (no-op when piped)
if [[ -t 1 ]]; then
    C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log()  { echo "${C_GREEN}[install]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[install] WARNING:${C_RESET} $*" >&2; }
err()  { echo "${C_RED}[install] ERROR:${C_RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (try: sudo $0)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Ensure OPT_DIR exists
# ---------------------------------------------------------------------------
mkdir -p "${OPT_DIR}"

# ---------------------------------------------------------------------------
# install_file SRC DST [MODE]
#   - Copies SRC into OPT_DIR (unless already there)
#   - Creates a symlink from OPT_DIR copy → DST (removing any stale link/file)
#   - Sets ownership root:root and mode (default 0644, 0755 for scripts)
# ---------------------------------------------------------------------------
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}" src_path=""

    # Resolve source
    if [[ -f "${src}" ]]; then
        src_path="${src}"
    elif [[ -f "${SCRIPT_DIR}/${src}" ]]; then
        src_path="${SCRIPT_DIR}/${src}"
    else
        warn "Source '${src}' not found in CWD or ${SCRIPT_DIR}; skipping → ${dst}"
        return 0
    fi

    local basename_src
    basename_src="$(basename "${src_path}")"
    local opt_copy="${OPT_DIR}/${basename_src}"

    # Copy into OPT_DIR (skip if already running from there)
    if [[ "${src_path}" != "${opt_copy}" ]]; then
        log "Copying ${src_path} → ${opt_copy}"
        cp -f -- "${src_path}" "${opt_copy}"
    fi

    # Fix ownership & permissions
    chown root:root "${opt_copy}"
    chmod "${mode}" "${opt_copy}"

    # Ensure parent of DST exists
    mkdir -p "$(dirname "${dst}")"

    # Remove stale/broken symlink or leftover file at DST
    if [[ -L "${dst}" ]]; then
        rm -f "${dst}"
    elif [[ -e "${dst}" ]]; then
        # A real file sits at dst (possibly from old cp-based install)
        rm -f "${dst}"
    fi

    ln -sf "${opt_copy}" "${dst}"
    log "Symlinked ${opt_copy} → ${dst}"
}

# ---------------------------------------------------------------------------
# Install core files
# ---------------------------------------------------------------------------
log "Installing automount files into ${OPT_DIR} …"

# Copy README.md into OPT_DIR (skip if already running from there)
if [[ "${SCRIPT_DIR}/README.md" != "${OPT_DIR}/README.md" ]]; then
    log "Copying README.md → ${OPT_DIR}/README.md"
    cp -f -- "${SCRIPT_DIR}/README.md" "${OPT_DIR}/README.md"
    chown root:root "${OPT_DIR}/README.md"
    chmod 0644 "${OPT_DIR}/README.md"
fi
# Copy installAutoMount.sh into OPT_DIR (skip if already running from there)
if [[ "${SCRIPT_DIR}/installAutoMount.sh" != "${OPT_DIR}/installAutoMount.sh" ]]; then
    log "Copying installAutoMount.sh → ${OPT_DIR}/installAutoMount.sh"
    cp -f -- "${SCRIPT_DIR}/installAutoMount.sh" "${OPT_DIR}/installAutoMount.sh"
    chown root:root "${OPT_DIR}/installAutoMount.sh"
    chmod 0755 "${OPT_DIR}/installAutoMount.sh"
fi

install_file mount_usb_memory.sh      /etc/mount_usb_memory.sh                 0755
install_file 99-auto-mount-sdxy.rules /etc/udev/rules.d/99-auto-mount-sdxy.rules 0644
install_file usb-mount@.service       /etc/systemd/system/usb-mount@.service    0644
install_file configure_shares.sh      /etc/configure_shares.sh                  0755
install_file add_rbind_mounts.sh      /etc/add_rbind_mounts.sh                  0755

# ---------------------------------------------------------------------------
# Mount propagation service (fixes LXC bind-mount visibility on PVE 9)
# ---------------------------------------------------------------------------
install_file mnt-shared-propagation.service /etc/systemd/system/mnt-shared-propagation.service 0644
systemctl daemon-reload
if ! systemctl is-enabled --quiet mnt-shared-propagation 2>/dev/null; then
    systemctl enable mnt-shared-propagation
    log "Enabled mnt-shared-propagation.service"
fi
# Apply immediately (in case containers are already running).
# mount --make-rshared requires a mount point; on a stock Debian
# /mnt is a plain directory, so ensure it is bind-mounted first.
mountpoint -q /mnt || mount --bind /mnt /mnt 2>/dev/null || true
mount --make-rshared /mnt 2>/dev/null || true

# ---------------------------------------------------------------------------
# Package checks — ntfs-3g is essential for reliable NTFS support
# ---------------------------------------------------------------------------
check_package() {
    local pkg="$1" desc="$2"
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        warn "${pkg} is not installed (${desc})."
        if [[ -t 0 ]]; then
            read -rp "  Install ${pkg} now? [Y/n]: " answer
            answer="${answer:-y}"
            if [[ "${answer,,}" =~ ^y ]]; then
                apt-get update -qq && apt-get install -y "${pkg}"
            fi
        else
            echo "  Run: apt-get install ${pkg}"
        fi
    else
        log "${pkg} — OK"
    fi
}

check_package ntfs-3g    "required for reliable NTFS read/write support"
check_package exfatprogs  "provides fsck.exfat and mkfs.exfat for exFAT filesystem support"

# ---------------------------------------------------------------------------
# ZFS unit overrides — strip deprecated Requires=systemd-udev-settle
# ---------------------------------------------------------------------------
override_remove_settle() {
    local svc="$1"
    if ! systemctl list-unit-files --type=service --all 2>/dev/null | grep -q "^${svc}\.service"; then
        return 0
    fi
    if ! systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
        return 0
    fi
    if systemctl cat "${svc}" 2>/dev/null | grep -q "^Requires=systemd-udev-settle"; then
        log "Overriding ${svc} to remove Requires=systemd-udev-settle"
        systemctl cat "${svc}" \
            | sed '/^#.*$/d' \
            | sed '/^Requires=systemd-udev-settle/d' \
            > "/etc/systemd/system/${svc}.service"
    fi
}

override_remove_settle zfs-import-cache
override_remove_settle zfs-import-scan

if systemctl is-enabled --quiet systemd-udev-settle 2>/dev/null; then
    log "Masking deprecated systemd-udev-settle"
    systemctl mask systemd-udev-settle
fi

# ---------------------------------------------------------------------------
# Reload udev & systemd
# ---------------------------------------------------------------------------
systemctl daemon-reload || true
udevadm control --reload-rules || true

# ---------------------------------------------------------------------------
# Offer to configure NFS / SMB shares
# ---------------------------------------------------------------------------
CONFIGURE_SHARES="${OPT_DIR}/configure_shares.sh"
if [[ -x "${CONFIGURE_SHARES}" ]]; then
    echo ""
    log "Share configuration — you can share ${C_GREEN}/mnt${C_RESET} over SMB and/or NFS."
    if [[ -t 0 ]]; then
        read -rp "Configure network shares now? [Y/n]: " answer
        answer="${answer:-y}"
        if [[ "${answer,,}" =~ ^y ]]; then
            bash "${CONFIGURE_SHARES}"
        else
            log "Skipped. Run ${CONFIGURE_SHARES} later to set up shares."
        fi
    else
        log "Non-interactive — run ${CONFIGURE_SHARES} manually to set up shares."
    fi
fi

# ---------------------------------------------------------------------------
# Offer to add recursive /mnt bind mounts to LXC containers
# ---------------------------------------------------------------------------
R_BIND_SCRIPT="${OPT_DIR}/add_rbind_mounts.sh"
if [[ -x "${R_BIND_SCRIPT}" ]]; then
    echo ""
    log "LXC recursive bind helper — converts /mnt binds to rbind so sub-mounts are visible."
    if [[ -t 0 ]]; then
        read -rp "Add recursive /mnt bind to LXC configs now? [Y/n]: " answer
        answer="${answer:-y}"
        if [[ "${answer,,}" =~ ^y ]]; then
            bash "${R_BIND_SCRIPT}"
        else
            log "Skipped. Run ${R_BIND_SCRIPT} later to update LXC configs."
        fi
    else
        log "Non-interactive — run ${R_BIND_SCRIPT} to add recursive binds later."
    fi
fi

# ---------------------------------------------------------------------------
echo ""
log "Install complete. Files stored in ${OPT_DIR} and symlinked into /etc."
log "Plug in a USB drive and check /mnt for the mounted volume."
echo ""
echo "  Troubleshooting LXC visibility:"
echo "    • The typical bind mount does not propagate sub-mounts into"
echo "      containers (e.g. if a USB drive mounts at /mnt/usb, it won't"
echo "      appear inside the container)."
echo "        mp0: /mnt,mp=/mnt"
echo "    • Instead, force a rbind mount:"
echo "        lxc.mount.entry: /mnt mnt none rbind,create=dir 0 0"
echo ""
