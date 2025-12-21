#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

getarg btrfs.snapshot || return 0

[ "$root" ] || root=$(getarg root=)

wait_for_dev -n /dev/root

return 0
