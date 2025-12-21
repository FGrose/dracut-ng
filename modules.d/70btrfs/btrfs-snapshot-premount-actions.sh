#!/bin/sh

[ -h /run/initramfs/btrfs_snap ] && {
    if src=$(findmnt -no SOURCE /run/rootfsbase); then
        btrfs_mnt=/run/rootfsbase
        ln -s "$src" /run/initramfs/rosnapshot
        mount -o remount,rw "$btrfs_mnt"
    else
        btrfs_mnt="$NEWROOT"
    fi
    # Restore default subvolume to ID 5 (FS_TREE)
    btrfs subvolume set-default 5 "$btrfs_mnt"
}
