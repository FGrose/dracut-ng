#!/bin/sh

# /run is mounted at $NEWROOT/run after switch_root;
# bind-mount it in place so that updates for /run actually land in /run.
mount -o bind /run "$NEWROOT"/run

if [ -h /dev/root ] && [ -d /run/initramfs/live/updates ] || [ -d /updates ]; then
    info "Applying updates to live image..."
    for d in /updates /run/initramfs/live/updates; do
        [ -d "$d" ] || continue
        (
            cd "$d" || return 0
            # avoid overwriting symlinks (e.g., /lib -> /usr/lib) with directories
            find . -depth -type d -exec mkdir -p "$NEWROOT/{}" \;
            find . -depth \! -type d -exec cp -a "{}" "$NEWROOT/{}" \;
        )
    done
fi

# release resources on iso-scan boots with rd.live.ram
if [ -d /run/initramfs/isoscan ] && {
    [ -f /run/initramfs/squashed.img ] || [ -f /run/initramfs/rootfs.img ]
}; then
    umount --detach-loop /run/initramfs/live
    umount /run/initramfs/isoscan
fi

umount "$NEWROOT"/run

