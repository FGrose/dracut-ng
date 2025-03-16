#!/bin/sh

set -x
# Extract latest, original, & current installed kernel versions.
# shellcheck disable=SC2046
set -- $(ls -rv /usr/lib/modules)
lkver="$1"
okver=$(eval printf '%s' $\{$#\})
# shellcheck disable=SC2046
set -- $(uname -rm)
KERNEL_VERSION="$1"

[ "$KERNEL_VERSION" = "$lkver" ] || {
    # If the current kernel version is not the latest..
    echo "Updating the ESP with the latest kernel and initramfs." > /dev/kmsg
    live_dir=$(readlink /run/initramfs/live_dir)
    if [ -d /run/initramfs/ESP/"$live_dir/${BOOTDIR:=boot/"$2"/loader}" ]; then
        IMG=initrd
        VM=linux
    else
        BOOTDIR=images/pxeboot
        IMG=initrd.img
        VM=vmlinuz
    fi
    umount /boot > /dev/kmsg 2>&1
    for _ in "${BOOTPATH:=/run/initramfs/ESP/$live_dir/$BOOTDIR}/initramfs-$KERNEL_VERSION".img\
             "$BOOTPATH/vmlinuz-$KERNEL_VERSION"; do
        umount "$_"
        rm "$_"
    done

    mv "$BOOTPATH/$VM" "$BOOTPATH/vmlinuz-$KERNEL_VERSION"
    mv "$BOOTPATH/vmlinuz-$lkver" "$BOOTPATH/$VM"
    mv "$BOOTPATH/$IMG" "$BOOTPATH/initramfs-$KERNEL_VERSION".img
    mv "$BOOTPATH/initramfs-$lkver".img "$BOOTPATH/$IMG"
    for _ in "$BOOTPATH/initramfs-$lkver".img "$BOOTPATH/vmlinuz-$lkver"; do
        # Zero-size these files.
        : > "$_"
    done

    # Update menu items requiring old kernel images.
    cp -a "${GRUB_cfg:=/run/initramfs/ESP/EFI/BOOT/grub.cfg}" "$GRUB_cfg".prev_kernel
    sed -i -r "s/(^\s*menu_item\s+'(Start|Make|Format|Reset) (t|a).*\s+').*('\s+.*'$live_dir.*)/\1$okver\4/" "$GRUB_cfg"
    umount /run/initramfs/ESP > /dev/kmsg 2>&1
}
