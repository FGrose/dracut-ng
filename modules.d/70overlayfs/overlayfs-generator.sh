#!/bin/sh
# overlayfs-generator

command -v getarg > /dev/null || . /lib/dracut-lib.sh

ovl_pt="$(getarg rd.overlay)" || exit 0

load_fstype overlay || Die 'OverlayFS is required but unavailable.'
command -v parse_Args > /dev/null || . /lib/overlayfs-lib.sh

volatile=volatile
[ "$ovl_pt" ] && get_ovl_pt "$ovl_pt" "${ovlfs_name:=os_rootfs}" ovl_pt
[ "$ovl_pt" = off ] && exit 0

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
[ "$rootok" ] || exit 0

GENERATOR_DIR="$2"
[ "$GENERATOR_DIR" ] || exit 1
[ -d "$GENERATOR_DIR" ] || mkdir -p "$GENERATOR_DIR"

rfstype="$(getarg rootfstype=)"
rflags="$(getarg rootflags=)"

overlayfs_mount_generator
