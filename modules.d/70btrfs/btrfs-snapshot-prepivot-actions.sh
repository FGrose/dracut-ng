#!/bin/sh
command -v getarg > /dev/null || . /lib/dracut-lib.sh

getarg btrfs.snapshot && {
    if findmnt /run/rootfsbase; then
        btrfs_mnt=/run/rootfsbase
    else
        btrfs_mnt="$NEWROOT"
    fi
    mount -o remount,rw "$btrfs_mnt"
    # Restore default subvolume to ID 5 (FS_TREE)
    btrfs subvolume set-default 5 "$btrfs_mnt"
    [ "$btrfs_mnt" = "$NEWROOT" ] || umount /run/rootfsbase
}
