#!/bin/sh
# Actions taken after NEWROOT mount but before pivoting out of the initramfs.

mount -o bind /run "$NEWROOT"/run

if [ -d /run/initramfs/live/updates ] || [ -d /updates ]; then
    info "Applying updates to live image..."
    # avoid overwriting symlinks (e.g. /lib -> /usr/lib) with directories
    for d in /updates /run/initramfs/live/updates; do
        [ -d "$d" ] || continue
        (
            cd "$d" || return 0
            find . -depth -type d -exec mkdir -p "$NEWROOT/{}" \;
            find . -depth \! -type d -exec cp -a "{}" "$NEWROOT/{}" \;
        )
    done
fi

PATH="$NEWROOT"/usr/sbin:"$NEWROOT"/usr/bin:"$NEWROOT"/sbin:"$NEWROOT"/bin:$PATH

getargbool 0 rd.overlayfs && {
    # Set SELinux attribute for OverlayFS directories.
    setfattr -n security.selinux -v system_u:object_r:root_t:s0 /sysroot /run/overlayfs /run/ovlwork

    mntDir=/run/initramfs/LiveOS_persist
    read -r live_dir < /run/initramfs/live_dir

    [ -f "$mntDir/$live_dir"/esp_uuid ] && {
        read -r esp_uuid < "$mntDir/$live_dir"/esp_uuid
        ln -sf /dev/disk/by-uuid/"$esp_uuid" /run/initramfs/espdev
    }

    [ -e /run/initramfs/espdev ] && {
        # Excludes /dev/mapper/live-rw & other traditional installations.

        # Readonly boot case:
        [ -h /run/overlayfs ] || ro=ro

        findmnt /run/initramfs/ESP > /dev/null 2>&1 || mount -t vfat -m ${ro:+-r} /run/initramfs/espdev /run/initramfs/ESP

        # shellcheck disable=SC2046
        set -- $(uname -rm)
        bkver="$1"
        if [ -d /run/initramfs/ESP/"$live_dir/${BOOTDIR:=boot/"$2"/loader}" ]; then
            IMG=initrd
            VM=linux
        else
            BOOTDIR=images/pxeboot
            IMG=initrd.img
            VM=vmlinuz
        fi
        BOOTPATH=/run/initramfs/ESP/"$live_dir/$BOOTDIR"
        [ "$ro" ] || mkdir -p "$BOOTPATH"

        # Condition on first autopartition boot or new persistent overlay:
        [ -f /run/initramfs/ESP/"$live_dir"/esp_uuid ] || {
            type update_BootConfig > /dev/null 2>&1 || . /lib/distribution-live-lib.sh

            esp_uuid=$(lsblk -npro UUID /run/initramfs/espdev)
            echo "$esp_uuid" > /run/initramfs/ESP/"$live_dir"/esp_uuid
            echo "$esp_uuid" > "$mntDir/$live_dir"/esp_uuid
            update_BootConfig
            for _ in "$BOOTPATH/initramfs-$bkver.img" "$BOOTPATH/vmlinuz-$bkver"; do
                # Zero-size these files.
                : > "$_"
            done
            ln -sf ../../dracut/modules.d/70dmsquash-live/dracut-update-kernel-initramfs.service \
                "$NEWROOT"/usr/lib/systemd/system/dracut-update-kernel-initramfs.service
            ln -sf ../dracut-update-kernel-initramfs.service \
                "$NEWROOT"/usr/lib/systemd/system/sysinit.target.wants/dracut-update-kernel-initramfs.service
        }

        mount --bind "$BOOTPATH/$IMG" "$BOOTPATH/initramfs-$bkver".img
        mount --bind "$BOOTPATH/$VM" "$BOOTPATH/vmlinuz-$bkver"
        mount --bind "$BOOTPATH" "$NEWROOT"/boot

        [ "$ro" ] || {
            sync -f /run/initramfs/ESP/"$live_dir"
            flock /run/initramfs/espdev fsck.fat -aV${VERBOSE:+v} /run/initramfs/espdev 2>&1
        }
    }

    # Hide the base rootfs partition mount.
    umount -l /run/rootfsbase > /dev/null 2>&1
}

# release resources on iso-scan boots with rd.live.ram
if [ -d /run/initramfs/isoscan ] && {
    [ -f /run/initramfs/rorootfs.img ] || [ -f /run/initramfs/rootfs.img ]
}; then
    umount --detach-loop /run/initramfs/live
    losetup -d /run/initramfs/isoloop
    umount /run/initramfs/isoscan
fi

umount "$NEWROOT"/run
