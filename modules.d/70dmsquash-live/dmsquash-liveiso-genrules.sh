#!/bin/sh

if [ "${root%%:*}" = "liveiso" ]; then
    {
        # shellcheck disable=SC2016
        printf 'KERNEL=="loop-control", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/dmsquash-live-root $$(losetup -P -f --show %s)p1"\n' \
            "${root#liveiso:}"
    } >> /etc/udev/rules.d/99-liveiso-mount.rules
fi
