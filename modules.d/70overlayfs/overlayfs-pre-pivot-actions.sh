#!/bin/sh
type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

getargbool rd.overlay || return 0

if [ -d /run/ovl/upperdir ]; then
    # Setup service for post switch-root relabelling of virtual filesystem objects.
    cp /usr/lib/systemd/system/overlayfs-root_t.service "$NEWROOT"/usr/lib/systemd/system/overlayfs-root_t.service
    cp /usr/bin/overlayfs-root_t.sh "$NEWROOT"/usr/bin/overlayfs-root_t.sh
    mkdir "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants
    ln -sf ../overlayfs-root_t.service \
        "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants/overlayfs-root_t.service
else
    # Change SELinux context type for OverlayFS directories on non-virtual filesystems.
    /run/rootfsbase/usr/bin/chcon system_u:object_r:root_t:s0 "$NEWROOT" /run/overlayfs /run/ovlwork
fi

# Hide the base rootfs mountpoint on non-live boots.
ismounted /run/initramfs/live || umount -l /run/rootfsbase
