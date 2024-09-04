#!/bin/sh

case "$root" in
    live:/dev/*)
        {
            printf 'KERNEL=="%s", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/dmsquash-live-root $$(readlink -f %s)"\n' \
                "${root#live:/dev/}" "${root#live:}"
            printf 'SYMLINK=="%s", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/dmsquash-live-root $$(readlink -f %s)"\n' \
                "${root#live:/dev/}" "${root#live:}"
        } >> /etc/udev/rules.d/99-live-squash.rules
        wait_for_dev -n "${root#live:}"
        ;;
    live:*)
        if [ -f "${root#live:}" ]; then
            /sbin/initqueue --settled --onetime --unique /sbin/dmsquash-live-root "${root#live:}"
        fi
        ;;
esac
