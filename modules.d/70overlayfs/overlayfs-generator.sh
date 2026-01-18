#!/bin/sh
# overlayfs-generator

command -v getarg > /dev/null || . /lib/dracut-lib-min.sh
command -v parse_cfgArgs > /dev/null || . /lib/overlayfs-lib.sh

btrfs_snap="$(getarg rd.btrfs.snapshot)" && {
    IFS=, parse_cfgArgs snp,"${btrfs_snap:=auto}"
    ln -s "$btrfs_snap" /run/initramfs/btrfs_snap
    : "${ovlfs_name:=os_snapfs}"
}
generator=generator
get_rd_overlay os_rootfs
[ "$OverlayFS" ] || [ "$btrfs_snap" ] || exit 0

[ "$root" ] || root=$(getarg root=)
case "$root" in
    ovl:LABEL=* | ovl:UUID=* | ovl:PARTUUID=* | ovl:PARTLABEL=*)
        root=ovl:$(label_uuid_to_dev "${root#ovl:}")
        rootok=1
        ;;
    ovl:/dev/*)
        rootok=1
        ;;
esac
[ "$rootok" ] || [ "$btrfs_snap" ] || exit 0

GENERATOR_DIR="$2"
[ "$GENERATOR_DIR" ] || exit 1
[ -d "$GENERATOR_DIR" ] || mkdir -p "$GENERATOR_DIR"

rfstype="$(getarg rootfstype=)"
rflags="$(getarg rootflags=)"

overlayfs_mount_generator
