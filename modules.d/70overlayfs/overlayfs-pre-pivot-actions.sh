#!/bin/sh

[ -h /run/initramfs/p_pt ] || return 0

# /run is mounted at $NEWROOT/run after switch_root;
# bind-mount it in place so that updates for /run actually land in /run.
mount -o bind /run "$NEWROOT"/run

if [ -d /run/ovl/upperdir ]; then
    # Setup service for post switch-root relabelling of virtual filesystem objects.
    cp /usr/lib/systemd/system/overlayfs-root_t.service "$NEWROOT"/usr/lib/systemd/system/overlayfs-root_t.service
    cp /usr/bin/overlayfs-root_t.sh "$NEWROOT"/usr/bin/overlayfs-root_t.sh
    mkdir "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants
    ln -sf ../overlayfs-root_t.service \
        "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants/overlayfs-root_t.service
else
    # Change SELinux context type for OverlayFS directories on non-virtual filesystems.
    PATH=/run/rootfsbase/usr/bin:/run/rootfsbase/usr/sbin:/run/rootfsbase/bin:/run/rootfsbase/sbin:$PATH
    chcon system_u:object_r:root_t:s0 "$NEWROOT" /run/overlayfs /run/ovlwork
fi

# Hide the base rootfs mountpoint.
umount -l /run/rootfsbase

umount "$NEWROOT"/run
