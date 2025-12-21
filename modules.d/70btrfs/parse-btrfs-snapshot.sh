#!/bin/sh

[ -h /run/initramfs/btrfs_snap ] || return 0

[ "$root" ] || root=$(getarg root=)

wait_for_dev -n /dev/root

return 0
