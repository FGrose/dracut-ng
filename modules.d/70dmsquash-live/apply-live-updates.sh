#!/bin/sh

if [ -h /dev/root ] && [ -d /run/initramfs/live/updates ] || [ -d /updates ]; then
    info "Applying updates to live image..."
    mount -o bind /run "$NEWROOT"/run
    # avoid overwriting symlinks (e.g. /lib -> /usr/lib) with directories
    for d in /updates /run/initramfs/live/updates; do
        [ -d "$d" ] || continue
        (
            cd "$d" || return 0
            find . -depth -type d -exec mkdir -p "$NEWROOT/{}" \;
            find . -depth \! -type d -exec cp -a "{}" "$NEWROOT/{}" \;
        )
    done
    umount "$NEWROOT"/run
fi

# Change SELinux context type for OverlayFS directories on non-virtual filesystems.
getargbool 0 rd.live.overlay.overlayfs && {
    PATH=/run/rootfsbase/usr/bin:/run/rootfsbase/usr/sbin:/run/rootfsbase/bin:/run/rootfsbase/sbin:$PATH
    chcon -t root_t /run/overlayfs /run/ovlwork
}

# release resources on iso-scan boots with rd.live.ram
if [ -d /run/initramfs/isoscan ] && {
    [ -f /run/initramfs/squashed.img ] || [ -f /run/initramfs/rootfs.img ]
}; then
    umount --detach-loop /run/initramfs/live
    umount /run/initramfs/isoscan
fi
