#!/bin/sh
type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

getargbool rd.overlayfs || return 0

if [ -h /run/overlayfs ]; then
    # Change SELinux context type for OverlayFS directories on non-virtual filesystems.
    PATH=/run/rootfsbase/usr/bin:/run/rootfsbase/usr/sbin:/run/rootfsbase/bin:/run/rootfsbase/sbin:$PATH
    chcon system_u:object_r:root_t:s0 /run/overlayfs /run/ovlwork
else
    # Change SELinux context type for OverlayFS directories on virtual filesystems.
    cp /usr/lib/systemd/system/overlayfs-root_t.service "$NEWROOT"/usr/lib/systemd/system/overlayfs-root_t.service
    cp /usr/bin/overlayfs-root_t.sh "$NEWROOT"/usr/bin/overlayfs-root_t.sh
    mkdir "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants
    ln -sf ../overlayfs-root_t.service \
        "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants/overlayfs-root_t.service
fi

# Hide the base rootfs mountpoint.
umount -l /run/rootfsbase
