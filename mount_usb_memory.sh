#!/bin/bash

ACTION=$1
DEVBASE=$2
DEVICE="/dev/${DEVBASE}"

MOUNT_INFO="/proc/mounts"
MOUNT_PARENT_PATH="/mnt/auto"
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ScriptName="$(basename "$0")"

MOUNT_CMD="/usr/bin/mount"
UMOUNT_CMD="/usr/bin/umount"
GREPO_CMD="/usr/bin/grep"
LSBLK_CMD="/usr/bin/lsblk"
FIND_CMD="/usr/bin/find"
MKDIR_CMD="/usr/bin/mkdir"
LOGGER_CMD="/usr/bin/logger"
RMDIR_CMD="/usr/bin/rmdir"

# See if this drive is already mounted
MOUNT_POINT=$(findmnt -n -o TARGET -S ${DEVICE})

do_mount() {
    if [[ -n ${MOUNT_POINT} ]]; then
        # Already mounted, exit
        ${LOGGER_CMD} "${ScriptName}: ${DEVICE} is already mounted at ${MOUNT_POINT}. Done"
        exit 1
    fi
    
    LABEL=$(${LSBLK_CMD} -no LABEL "${DEVICE}")
    FS_TYPE=$(${LSBLK_CMD} -no FSTYPE "${DEVICE}")
    
    if [[ -z "${LABEL}" ]]; then
        LABEL=${DEVBASE}
    elif ${GREPO_CMD} -q " ${MOUNT_PARENT_PATH}/${LABEL} " ${MOUNT_INFO}; then
        # Already in use, make a unique one
        LABEL+="-${DEVBASE}"
    fi
    
    MOUNT_POINT="${MOUNT_PARENT_PATH}/${LABEL}"
    ${LOGGER_CMD} "${ScriptName}: Mounting ${DEVICE} at ${MOUNT_POINT} ..."
    
    if ! ${MKDIR_CMD} -p "${MOUNT_POINT}"; then
        ${LOGGER_CMD} "${ScriptName}: Failed to create mount point ${MOUNT_POINT}. Exiting."
        exit 1
    fi
    
    # Global mount options
    OPTS="rw,relatime"

    # File system type specific mount options
    if [[ ${FS_TYPE} == "vfat" ]]; then
        OPTS+=",users,gid=100,umask=000,shortname=mixed,utf8=1,flush"
    fi

    if ! ${MOUNT_CMD} -o ${OPTS} ${DEVICE} ${MOUNT_POINT}; then
        # Error during mount process: cleanup mountpoint
        ${LOGGER_CMD} "${ScriptName}: Error during mount process. Cleanup & exit"
        ${RMDIR_CMD} "${MOUNT_POINT}"
        exit 1
    fi

    ${LOGGER_CMD} "${ScriptName}: ${DEVICE} - Mount done! Exit"
}

do_unmount() {
    if [[ -n ${MOUNT_POINT} ]]; then
        ${UMOUNT_CMD} -l ${DEVICE}
    fi

    # Delete all empty dirs in MOUNT_PARENT_PATH that aren't being used as mount points
    for f in ${MOUNT_PARENT_PATH}/* ; do
        if [[ -n $(${FIND_CMD} "$f" -maxdepth 0 -type d -empty) ]]; then
            if ! ${GREPO_CMD} -q " $f " ${MOUNT_INFO}; then
                ${RMDIR_CMD} "$f"
            fi
        fi
    done
}

case "${ACTION}" in
    add)
        ${LOGGER_CMD} "${ScriptName}: ${DEVICE} - Action is 'add'"
        do_mount
        ;;
    remove)
        ${LOGGER_CMD} "${ScriptName}: ${DEVICE} - Action is 'remove (umount)'"
        do_unmount
        ;;
esac
