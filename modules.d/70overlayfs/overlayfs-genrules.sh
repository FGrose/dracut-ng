#!/bin/sh

case "$root" in
   ovl:/dev/*)
        {
            printf 'KERNEL=="%s", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/root-overlayfs $$(readlink -f %s)"\n' \
                "${root#ovl:/dev/}" "${root#ovl:}"
            printf 'SYMLINK=="%s", ENV{DEVTYPE}=="partition", RUN+="/sbin/initqueue --settled --onetime --unique /sbin/root-overlayfs $$(readlink -f %s)"\n' \
                "${root#ovl:/dev/}" "${root#ovl:}"
        } >> /etc/udev/rules.d/99-overlayfs.rules
        wait_for_dev -n /dev/root
        ;;
esac
