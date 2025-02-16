#!/bin/sh
type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

getargbool rd.overlayfs || return 0

# Change SELinux context type for OverlayFS directories on non-virtual filesystems.
[ -h /run/overlayfs ] || {
    PATH=/run/rootfsbase/usr/bin:/run/rootfsbase/usr/sbin:/run/rootfsbase/bin:/run/rootfsbase/sbin:$PATH
    chcon -t root_t /run/overlayfs /run/ovlwork
}

# Hide the base rootfs mountpoint.
umount -l /run/rootfsbase
