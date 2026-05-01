#!/bin/sh

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
    "$NEWROOT"/usr/bin/chcon system_u:object_r:root_t:s0 "$NEWROOT" /run/overlayfs /run/ovlwork
fi

[ -h /run/initramfs/ro_all ] && {
    FSTAB="${NEWROOT}/etc/fstab"
    while read -r device mountpoint fstype options dump pass || [ "$device" ]; do
        case "$device" in '' | \#*) continue ;; esac
        [ "$mountpoint" = '/' ] && continue
        case "$fstype" in
            proc | sysfs | devpts | devtmpfs | tmpfs | swap) continue ;;
        esac

        SAFE_NAME=$(str_replace "$mountpoint" '/' '_')
        LOWER="/run/ovl${mountpoint}"
        UPPER="/run/ovl/${SAFE_NAME}/upper"
        WORK="/run/ovl/${SAFE_NAME}/work"

        mkdir -p "$LOWER" "$UPPER" "$WORK"
        mount -r -t "$fstype" -o "${options},ro" "$device" "$LOWER"
        mount -t overlay ["$mountpoint"] \
            -o lowerdir="${LOWER}",upperdir="${UPPER}",workdir="${WORK}",fsync=volatile \
            "${NEWROOT}${mountpoint}"
    done < "$FSTAB"
}

# Hide the base rootfs mountpoint on non-live boots.
ismounted /run/initramfs/live || umount -l /run/rootfsbase
umount "$NEWROOT"/run
