#!/bin/sh
# Actions taken after NEWROOT mount but before pivoting out of the initramfs.

# /run is mounted at $NEWROOT/run after switch_root;
# bind-mount it in place so that updates for /run actually land in /run.
mount -o bind /run "$NEWROOT"/run

if [ -d /run/initramfs/live/updates ] || [ -d /updates ]; then
    info "Applying updates to live image..."
    for d in /updates /run/initramfs/live/updates; do
        [ -d "$d" ] || continue
        (
            cd "$d" || return 0
            # Avoid overwriting symlinks (e.g., /lib -> /usr/lib) with directories.
            find . -depth -type d -exec mkdir -p "$NEWROOT/{}" \;
            find . -depth \! -type d -exec cp -a "{}" "$NEWROOT/{}" \;
        )
    done
fi

getargbool 0 rd.overlayfs && {
    mntDir=/run/LiveOS_persist
    live_dir=$(readlink /run/initramfs/live_dir)

    [ -f "$mntDir/$live_dir"/esp_uuid ] && {
        read -r esp_uuid < "$mntDir/$live_dir"/esp_uuid
        ln -sf /dev/disk/by-uuid/"$esp_uuid" /run/initramfs/espdev
    }

    [ -e /run/initramfs/espdev ] && {
        # Excludes /dev/mapper/live-rw & other traditional installations.

        # Readonly boot case:
        [ -h /run/overlayfs-r ] && ro=ro

        ismounted /run/initramfs/ESP \
            || mount -t vfat -m -o ${ro:+ro,}nocase,shortname=win95 /run/initramfs/espdev /run/initramfs/ESP

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
            # Use distribution-specific code to update the boot configuration files.
            type update_BootConfig > /dev/null 2>&1 || . /lib/distribution-lib.sh

            esp_uuid=$(blkid /run/initramfs/espdev)
            esp_uuid="${esp_uuid#* UUID=\"}"
            esp_uuid="${esp_uuid%%\"*}"
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

