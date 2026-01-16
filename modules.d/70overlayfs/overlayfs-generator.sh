#!/bin/sh
# overlayfs-generator

command -v getarg > /dev/null || . /lib/dracut-lib.sh

btrfs_snap="$(getarg rd.btrfs.snapshot)" && {
    command -v get_p_pt > /dev/null || . /lib/overlayfs-lib.sh
    IFS=, parse_cfgArgs snp,"${btrfs_snap:=auto}"
    ln -s "$btrfs_snap" /run/initramfs/btrfs_snap
    : "${ovlfs_name:=os_snapfs}"
}
p_pt="$(getarg rd.overlay)" || [ "$btrfs_snap" ] || exit 0

load_fstype overlay || Die 'OverlayFS is required but unavailable.'
command -v get_p_pt > /dev/null || . /lib/overlayfs-lib.sh

volatile=volatile
[ "$p_pt" ] && get_p_pt "$p_pt" "${ovlfs_name:=os_rootfs}" p_pt
[ "$p_pt" = off ] && exit 0

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
