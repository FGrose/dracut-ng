#!/bin/sh
# overlayfs-generator

command -v get_rd_overlay > /dev/null || . /lib/overlayfs-lib.sh

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

get_rd_overlay os_rootfs
[ "$OverlayFS"] || exit 0

rfstype="$(getarg rootfstype=)"
rflags="$(getarg rootflags=)"

overlayfs_mount_generator
