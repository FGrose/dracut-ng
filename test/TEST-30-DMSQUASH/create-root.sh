#!/bin/sh

trap 'poweroff -f' EXIT
set -e

# create a single partition using 50% of the capacity of the image file created by test_setup() in test.sh
sfdisk /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root << EOF
2048,652688
EOF

udevadm settle

mkfs.ext4 -q -L dracut /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root-part1
mkdir -p /root
mount -t ext4 /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root-part1 /root
mkdir -p /root/run /root/testdir
cp -a -t /root /source/*
echo "Creating squashfs"
mksquashfs /source /root/testdir/rootfs.img -quiet

# Write the erofs compressed filesystem to the partition
if modprobe erofs && command -v mkfs.erofs; then
    EROFS=Y
    echo "Creating erofs"
    mkfs.erofs /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root_erofs /source
fi

# Copy rootfs.img to the NTFS drive if exists
if modprobe ntfs3 && command -v mkfs.ntfs; then
    NTFS=Y
    mkfs.ntfs -q -F -L dracut_ntfs /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root_ntfs
    mkdir -p /root_ntfs
    mount -t ntfs3 /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_root_ntfs /root_ntfs
    mkdir -p /root_ntfs/run /root_ntfs/testdir
    cp /root/testdir/rootfs.img /root_ntfs/testdir/rootfs.img
fi

umount /root

{
    echo "dracut-root-block-created"
    echo "EROFS=$EROFS"
    echo "NTFS=$NTFS"
} | dd oflag=direct,dsync of=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_marker status=none
poweroff -f
