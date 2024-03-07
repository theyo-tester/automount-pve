#!/bin/bash

ACTION=$1
DEVBASE=$2
DEVICE="/dev/${DEVBASE}"

MOUNT_INFO=/proc/mounts
MOUNT_PARENT_PATH=/mnt/auto
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ScriptName="$(basename "$0")"
# See if this drive is already mounted
MOUNT_POINT=$(/usr/bin/mount | /usr/bin/grep ${DEVICE} | /usr/bin/awk '{ print $3 }')

do_mount()
{
    if [[ -n ${MOUNT_POINT} ]]; then
        # Already mounted, exit
        logger "${ScriptName}: ${DEVICE} is already mounted at ${MOUNT_POINT}. Done"
        exit 1
    fi
    
    # Get info for this drive: $ID_FS_LABEL, $ID_FS_UUID, and $ID_FS_TYPE
    # Figure out a mount point to use
    LABEL=$(lsblk -no label "${DEVICE}")
    
    if [[ -z "${LABEL}" ]]; then
        LABEL=${DEVBASE}
    elif /bin/grep -q " ${MOUNT_PARENT_PATH}/${LABEL} " $MOUNT_INFO; then
        # Already in use, make a unique one
        LABEL+="-${DEVBASE}"
    fi
    MOUNT_POINT="${MOUNT_PARENT_PATH}/${LABEL}"
    logger "${ScriptName}: Mounting ${DEVICE} at ${MOUNT_POINT} ..."
    /usr/bin/mkdir -p ${MOUNT_POINT}

    # Global mount options
    OPTS="rw,relatime"

    # File system type specific mount options
    if [[ ${ID_FS_TYPE} == "vfat" ]]; then
        OPTS+=",users,gid=100,umask=000,shortname=mixed,utf8=1,flush"
    fi

    if ! /usr/bin/mount -o ${OPTS} ${DEVICE} ${MOUNT_POINT}; then
        # Error during mount process: cleanup mountpoint
        logger "${ScriptName}: Error durring mount process. CleauUp & exit"
        /usr/bin/rmdir ${MOUNT_POINT}
        exit 1
    fi
    logger "${ScriptName}: ${DEVICE} - Mount done! Exit"
}

do_unmount()
{
    if [[ -n ${MOUNT_POINT} ]]; then
        /usr/bin/umount -l ${DEVICE}
    fi

    # Delete all empty dirs in /media that aren't being used as mount points. 
    for f in ${MOUNT_PARENT_PATH}/* ; do
        if [[ -n $(/usr/bin/find "$f" -maxdepth 0 -type d -empty) ]]; then
            if ! /usr/bin/grep -q " $f " $MOUNT_INFO; then
                /usr/bin/rmdir "$f"
            fi
        fi
    done
}
case "${ACTION}" in
    add)
        logger "${ScriptName}: ${DEVICE} - Action is 'add'"
        do_mount
        ;;
    remove)
        logger "${ScriptName}: ${DEVICE} - Action is 'remove (umount)'"
        do_unmount
        ;;
esac
