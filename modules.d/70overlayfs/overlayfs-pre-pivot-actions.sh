#!/bin/sh
type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

getargbool 0 rd.overlayfs || return 0

# /run is mounted at $NEWROOT/run after switch_root;
# bind-mount it in place so that updates for /run actually land in /run.
mount -o bind /run "$NEWROOT"/run

if [ -h /run/overlayfs ]; then
    # Change SELinux context type for OverlayFS directories on non-virtual filesystems.
    PATH=/run/rootfsbase/usr/bin:/run/rootfsbase/usr/sbin:/run/rootfsbase/bin:/run/rootfsbase/sbin:$PATH
    chcon -t root_t / /run/overlayfs /run/ovlwork
else
    # Prepare systemd service to change SELinux contexts for OverlayFS upper directories in the virtual /run filesystem.
    cp /usr/lib/systemd/system/overlayfs-root_t.service "$NEWROOT"/usr/lib/systemd/system/overlayfs-root_t.service
    cp /usr/bin/overlayfs-root_t.sh "$NEWROOT"/usr/bin/overlayfs-root_t.sh
    mkdir "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants
    ln -sf ../overlayfs-root_t.service \
        "$NEWROOT"/usr/lib/systemd/system/local-fs-pre.target.wants/overlayfs-root_t.service

    # Add SELinux context type label rule for OverlayFS directories on virtual filesystems.
    #chroot "$NEWROOT" semanage fcontext -a -t root_t -f d '^/($|run/(overlayfs$|ovlwork$))'
    # Add SELinux context type label rules for directories or files created by the above change.
    #chroot "$NEWROOT" semanage fcontext -a -t selinux_config_t -f d '^/etc/selinux(/[^/]+)?'
    #chroot "$NEWROOT" semanage fcontext -a -t default_context_t '^/etc/selinux/contexts(/.*)?'
    #chroot "$NEWROOT" semanage fcontext -a -t file_context_t '^/etc/selinux/contexts/files(/.*)?'
    #chroot "$NEWROOT" semanage fcontext -a -t semanage_store_t '^/var/lib/selinux(/.*)?'
    #chroot "$NEWROOT" semanage fcontext -a -t semanage_read_lock_t '^/var/lib/selinux/targeted/semanage.read.LOCK$'
    #chroot "$NEWROOT" semanage fcontext -a -t semanage_trans_lock_t '^/var/lib/selinux/targeted/semanage.trans.LOCK$'
    #chroot "$NEWROOT" sed -i -r '/^SELINUX=/ s/enforcing/permissive/' /etc/selinux/config
    #chroot "$NEWROOT" restorecon -Rv -T 0 /etc/selinux /var/lib/selinux
fi

# Hide the base rootfs mountpoint.
umount -l /run/rootfsbase

umount "$NEWROOT"/run
