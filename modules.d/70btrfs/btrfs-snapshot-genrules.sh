#!/bin/sh

[ -h /run/initramfs/btrfs_snap ] && {
    {
        printf 'KERNEL=="%s", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/btrfs-snapshot $$(readlink -f %s)"\n' \
            "${root#block:/dev/}" "${root#block:}"
        printf 'SYMLINK=="%s", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/btrfs-snapshot $$(readlink -f %s)"\n' \
            "${root#block:/dev/}" "${root#block:}"
    } >> /etc/udev/rules.d/99-btrfs-snapshot.rules
    
    rm /etc/udev/rules.d/99-root.rules
    rm "$hookdir"/initqueue/settled/blocksymlink.sh

    wait_for_dev -n /dev/root
}
