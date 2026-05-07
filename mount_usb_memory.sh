#!/bin/bash
# -u: treat unset variables as errors; -o pipefail: pipeline returns rightmost non-zero.
# -e is intentionally omitted: this script uses explicit error handling and many
# commands are expected to fail (e.g. findmnt when device is not mounted).
set -uo pipefail

# ---------------------------------------------------------------------------
# mount_usb_memory.sh — automount/unmount handler for USB-attached storage
# Repo: https://github.com/theyo-tester/automount-pve
# Called by usb-mount@.service via udev rules
# Updated for Proxmox 9 (Debian Trixie)

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 {add|remove} DEVBASE" >&2
    exit 1
fi

ACTION="$1"
DEVBASE="$2"
DEVICE="/dev/${DEVBASE}"

MOUNT_PARENT_PATH="/mnt"
ScriptName="$(basename "$0")"

MOUNT_CMD="/usr/bin/mount"
UMOUNT_CMD="/usr/bin/umount"
LSBLK_CMD="/usr/bin/lsblk"
FIND_CMD="/usr/bin/find"
MKDIR_CMD="/usr/bin/mkdir"
LOGGER_CMD="/usr/bin/logger"
RMDIR_CMD="/usr/bin/rmdir"
BLKID_CMD="/usr/sbin/blkid"

# See if this drive is already mounted
MOUNT_POINT=$(/usr/bin/findmnt -n -o TARGET -S "${DEVICE}" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Filesystem check — runs a non-interactive repair before mounting.
# For NTFS volumes this is especially important to clear the "dirty" flag
# that Windows tends to leave behind (hibernate / improper eject).
#
# Returns 0 if it is safe to proceed with mounting, non-zero if uncorrectable
# errors were found and the mount should be aborted.
# ---------------------------------------------------------------------------
do_fsck() {
    local dev="$1" fstype="$2"
    local fsck_rc=0 output=""
    case "${fstype}" in
        ntfs|ntfs3)
            if command -v ntfsfix >/dev/null 2>&1; then
                ${LOGGER_CMD} "${ScriptName}: Running ntfsfix -d on ${dev}"
                output=$(ntfsfix -d "${dev}" 2>&1) || fsck_rc=$?
                while IFS= read -r line; do
                    ${LOGGER_CMD} "${ScriptName}: ntfsfix: ${line}"
                done <<< "${output}"
                if [[ ${fsck_rc} -ne 0 ]]; then
                    # Non-fatal: ntfs-3g can mount dirty volumes without ntfsfix succeeding
                    ${LOGGER_CMD} "${ScriptName}: WARNING — ntfsfix exited ${fsck_rc} on ${dev}; proceeding (ntfs-3g handles dirty volumes)"
                fi
            else
                ${LOGGER_CMD} "${ScriptName}: WARNING — ntfsfix not found; skipping NTFS check on ${dev}"
            fi
            ;;
        vfat)
            if command -v fsck.vfat >/dev/null 2>&1; then
                ${LOGGER_CMD} "${ScriptName}: Running fsck.vfat -a on ${dev}"
                output=$(fsck.vfat -a "${dev}" 2>&1) || fsck_rc=$?
                while IFS= read -r line; do
                    ${LOGGER_CMD} "${ScriptName}: fsck.vfat: ${line}"
                done <<< "${output}"
                # fsck.vfat: 0=clean/repaired, 1=fixable errors corrected, 2+=fatal
                if [[ ${fsck_rc} -ge 2 ]]; then
                    ${LOGGER_CMD} "${ScriptName}: ERROR — fsck.vfat exited ${fsck_rc} on ${dev}; aborting mount"
                    return "${fsck_rc}"
                elif [[ ${fsck_rc} -eq 1 ]]; then
                    ${LOGGER_CMD} "${ScriptName}: INFO — fsck.vfat corrected errors on ${dev}"
                fi
            fi
            ;;
        exfat)
            if command -v fsck.exfat >/dev/null 2>&1; then
                ${LOGGER_CMD} "${ScriptName}: Running fsck.exfat -y on ${dev}"
                output=$(fsck.exfat -y "${dev}" 2>&1) || fsck_rc=$?
                while IFS= read -r line; do
                    ${LOGGER_CMD} "${ScriptName}: fsck.exfat: ${line}"
                done <<< "${output}"
                # fsck.exfat: 0=clean, 1=errors corrected, 2+=uncorrectable
                if [[ ${fsck_rc} -ge 2 ]]; then
                    ${LOGGER_CMD} "${ScriptName}: ERROR — fsck.exfat exited ${fsck_rc} on ${dev}; aborting mount"
                    return "${fsck_rc}"
                elif [[ ${fsck_rc} -eq 1 ]]; then
                    ${LOGGER_CMD} "${ScriptName}: INFO — fsck.exfat corrected errors on ${dev}"
                fi
            fi
            ;;
        ext2|ext3|ext4)
            if command -v e2fsck >/dev/null 2>&1; then
                ${LOGGER_CMD} "${ScriptName}: Running e2fsck -p on ${dev}"
                output=$(e2fsck -p "${dev}" 2>&1) || fsck_rc=$?
                while IFS= read -r line; do
                    ${LOGGER_CMD} "${ScriptName}: e2fsck: ${line}"
                done <<< "${output}"
                # e2fsck exit codes are bitmasks:
                #   bit 0 (1) = errors corrected
                #   bit 1 (2) = errors corrected, reboot recommended (root fs; not relevant for USB)
                #   bit 2 (4) = errors left uncorrected  → fatal
                #   >=8       = operational/usage/library error → fatal
                if (( (fsck_rc & 4) || fsck_rc >= 8 )); then
                    ${LOGGER_CMD} "${ScriptName}: ERROR — e2fsck exited ${fsck_rc} on ${dev}; aborting mount"
                    return "${fsck_rc}"
                elif [[ ${fsck_rc} -ne 0 ]]; then
                    ${LOGGER_CMD} "${ScriptName}: INFO — e2fsck corrected errors on ${dev} (rc=${fsck_rc})"
                fi
            fi
            ;;
        xfs)
            if command -v xfs_repair >/dev/null 2>&1; then
                # Use -n (no-modify) + -e (exit non-zero on errors) for a safe pre-mount check.
                # Do NOT run xfs_repair without -n in an automount context: it will attempt live
                # repair and, if the log is dirty, will exit non-zero without -L (which would
                # destroy the log). XFS replays its own journal on mount; actual repair requires
                # offline manual intervention (xfs_repair [-L]).
                ${LOGGER_CMD} "${ScriptName}: Running xfs_repair -n -e on ${dev} (check only; no repair)"
                output=$(xfs_repair -n -e "${dev}" 2>&1) || fsck_rc=$?
                while IFS= read -r line; do
                    ${LOGGER_CMD} "${ScriptName}: xfs_repair: ${line}"
                done <<< "${output}"
                if [[ ${fsck_rc} -ne 0 ]]; then
                    # Non-fatal: XFS will attempt journal recovery on mount itself
                    ${LOGGER_CMD} "${ScriptName}: WARNING — xfs_repair -n found errors on ${dev} (rc=${fsck_rc}); XFS will attempt journal recovery on mount"
                fi
            fi
            ;;
        btrfs)
            # btrfs check in repair mode is risky; just log a note
            ${LOGGER_CMD} "${ScriptName}: btrfs detected on ${dev}; skipping offline check (use btrfs scrub after mount)"
            ;;
        *)
            ${LOGGER_CMD} "${ScriptName}: No fsck handler for fstype '${fstype}' on ${dev}; skipping"
            ;;
    esac
}

# ---------------------------------------------------------------------------
do_mount() {
    if [[ -n ${MOUNT_POINT} ]]; then
        # Already mounted, exit
        ${LOGGER_CMD} "${ScriptName}: ${DEVICE} is already mounted at ${MOUNT_POINT}. Done"
        exit 0
    fi

    # Probe filesystem — prefer blkid, fall back to lsblk
    FS_TYPE=$(${BLKID_CMD} -o value -s TYPE "${DEVICE}" 2>/dev/null || true)
    if [[ -z "${FS_TYPE}" ]]; then
        FS_TYPE=$(${LSBLK_CMD} -no FSTYPE "${DEVICE}" 2>/dev/null || true)
    fi

    if [[ -z "${FS_TYPE}" ]]; then
        ${LOGGER_CMD} "${ScriptName}: Unable to determine filesystem type for ${DEVICE}. Skipping."
        exit 1
    fi

    LABEL=$(${LSBLK_CMD} -no LABEL "${DEVICE}" 2>/dev/null || true)

    # Sanitize the filesystem label to prevent path-traversal and injection:
    #   '/' → '_'           blocks path escape (e.g. "../../etc" on NTFS)
    #   control chars → ''  removes null, newline and other non-printable bytes
    #   spaces → '_'        avoids /proc/mounts \040-escaping mismatches
    #   leading dots → ''   blocks "." / ".." path segments
    LABEL="$(printf '%s' "${LABEL}" \
        | tr '/' '_' \
        | tr -d '\001-\031\177' \
        | sed 's/[[:space:]]/_/g; s/^\.*//')"

    if [[ -z "${LABEL}" ]]; then
        LABEL=${DEVBASE}
    elif /usr/bin/findmnt -n -o TARGET "${MOUNT_PARENT_PATH}/${LABEL}" >/dev/null 2>&1; then
        # Mount point already in use — make a unique label
        LABEL+="-${DEVBASE}"
    fi

    MOUNT_POINT="${MOUNT_PARENT_PATH}/${LABEL}"
    ${LOGGER_CMD} "${ScriptName}: Detected fstype=${FS_TYPE} on ${DEVICE}; target ${MOUNT_POINT}"

    # --- filesystem check (before mount) ---
    if ! do_fsck "${DEVICE}" "${FS_TYPE}"; then
        ${LOGGER_CMD} "${ScriptName}: Filesystem check failed on ${DEVICE}; aborting mount"
        exit 1
    fi

    if ! ${MKDIR_CMD} -p "${MOUNT_POINT}"; then
        ${LOGGER_CMD} "${ScriptName}: Failed to create mount point ${MOUNT_POINT}. Exiting."
        exit 1
    fi

    # --- build mount options per filesystem type ---
    OPTS="rw,relatime"
    USE_NTFS3G=0

    case "${FS_TYPE}" in
        vfat)
            OPTS+=",users,gid=100,umask=000,shortname=mixed,utf8=1,flush"
            ;;
        ntfs|ntfs3)
            # Prefer ntfs-3g (FUSE) over the kernel ntfs/ntfs3 driver for
            # reliability — it handles dirty volumes and is more mature.
            if command -v ntfs-3g >/dev/null 2>&1; then
                USE_NTFS3G=1
                OPTS="rw,relatime,big_writes,windows_names,uid=0,gid=0,umask=000"
            else
                ${LOGGER_CMD} "${ScriptName}: WARNING — ntfs-3g not installed; falling back to kernel ntfs3 driver"
                OPTS+=",uid=0,gid=0,umask=000"
                FS_TYPE="ntfs3"   # ensure we request the kernel driver explicitly
            fi
            ;;
        exfat)
            OPTS+=",uid=0,gid=0,umask=000"
            ;;
        ext2|ext3|ext4)
            # defaults are fine
            ;;
        xfs|btrfs)
            # defaults are fine
            ;;
        *)
            ${LOGGER_CMD} "${ScriptName}: Filesystem '${FS_TYPE}' — using generic mount options"
            ;;
    esac

    # --- perform mount ---
    local mount_rc=0
    if [[ ${USE_NTFS3G} -eq 1 ]]; then
        ${LOGGER_CMD} "${ScriptName}: Mounting ${DEVICE} via ntfs-3g at ${MOUNT_POINT}"
        if ! ntfs-3g -o "${OPTS}" "${DEVICE}" "${MOUNT_POINT}"; then
            mount_rc=1
        fi
    else
        if ! ${MOUNT_CMD} -t "${FS_TYPE}" -o "${OPTS}" "${DEVICE}" "${MOUNT_POINT}"; then
            mount_rc=1
        fi
    fi

    if [[ ${mount_rc} -ne 0 ]]; then
        ${LOGGER_CMD} "${ScriptName}: Error mounting ${DEVICE} (${FS_TYPE}). Cleanup & exit"
        ${RMDIR_CMD} "${MOUNT_POINT}" 2>/dev/null || true
        exit 1
    fi

    # Ensure mount propagation is shared recursively to ${MOUNT_PARENT_PATH}.
    # --make-rshared (not --make-shared) is needed so that nested mounts
    # (e.g. a second USB drive under /mnt) are also visible inside LXC containers.
    mount --make-rshared "${MOUNT_PARENT_PATH}" 2>/dev/null || true

    ${LOGGER_CMD} "${ScriptName}: ${DEVICE} (${FS_TYPE}) mounted at ${MOUNT_POINT} — done"
}

# ---------------------------------------------------------------------------
do_unmount() {
    if [[ -n "${MOUNT_POINT}" ]]; then
        ${LOGGER_CMD} "${ScriptName}: Unmounting ${DEVICE} from ${MOUNT_POINT}"
        ${UMOUNT_CMD} -l "${DEVICE}"
    fi

    # Delete all empty dirs in MOUNT_PARENT_PATH that aren't being used as mount points
    for f in "${MOUNT_PARENT_PATH}"/* ; do
        [[ -e "$f" ]] || continue
        if [[ -n $(${FIND_CMD} "$f" -maxdepth 0 -type d -empty 2>/dev/null) ]]; then
            if ! /usr/bin/findmnt -n -o TARGET "$f" >/dev/null 2>&1; then
                ${RMDIR_CMD} "$f" 2>/dev/null || true
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
case "${ACTION}" in
    add)
        ${LOGGER_CMD} "${ScriptName}: ${DEVICE} — Action is 'add'"
        do_mount
        ;;
    remove)
        ${LOGGER_CMD} "${ScriptName}: ${DEVICE} — Action is 'remove (umount)'"
        do_unmount
        ;;
    *)
        ${LOGGER_CMD} "${ScriptName}: Unknown action '${ACTION}' for ${DEVICE}"
        exit 1
        ;;
esac
