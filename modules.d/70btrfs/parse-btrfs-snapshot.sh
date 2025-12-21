#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

getarg btrfs.snapshot || exit 0

[ "$root" ] || root=$(getarg root=)

#cancel_wait_for_dev -n "${root#block:}"
wait_for_dev -n /dev/root

return 0
