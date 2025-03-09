#!/bin/sh

# turn off debugging
set +x

# INFO_SHOW(_while_quiet) flag from kernel command line parameters
INFO_SHOW=$1

printf "%s" "$$" > /run/initramfs/loginit.pid

# shellcheck disable=SC2015
[ -e /dev/kmsg ] && exec 5> /dev/kmsg || exec 5> /dev/null
exec 6> /run/initramfs/init.log

while read -r line || [ -n "$line" ]; do
    if [ "$line" = "DRACUT_LOG_END" ]; then
        rm -f -- /run/initramfs/loginit.pipe
        exit 0
    fi
    echo "<31>dracut: $line" >&5
    # if "quiet" is specified we output to /dev/console
    [ "$INFO_SHOW" = "yes" ] && echo "dracut: $line"
    echo "$line" >&6
done
