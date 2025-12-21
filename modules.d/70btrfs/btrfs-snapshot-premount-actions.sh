#!/bin/sh

[ -h /run/initramfs/btrfs_snap ] && {
    local s m
    if { while read -r s m _; do
        [ "$m" = /run/rootfsbase ] && src="$s" && break
    done < /proc/mounts; }; then
        btrfs_mnt=/run/rootfsbase
        ln -s "$src" /run/initramfs/rosnapshot
        mount -o remount,rw "$btrfs_mnt"
    else
        btrfs_mnt="$NEWROOT"
    fi
    # Restore default subvolume to ID 5 (FS_TREE)
    btrfs subvolume set-default 5 "$btrfs_mnt"
}
