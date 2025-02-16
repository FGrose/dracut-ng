#!/bin/sh
# overlayfs-generator
SourcPath=/usr/lib/dracut/modules.d/70overlayfs/overlayfs-generator.sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

OverlayFS="$(getarg rd.overlayfs)" || exit 0
load_fstype overlay || die 'OverlayFS is required but unavailable.'

case "${OverlayFS%%[=/]*}" in
    0 | no | off) exit 0 ;;
    '' | 1) ovlfs_name=os_rootfs ;;
    "${OverlayFS%%,*}") ovlfs_name=${OverlayFS%%,*} ;;
    *) # devspec present
        # with source name prefix
        [ "${OverlayFS%%,*}" != "$OverlayFS" ] && ovlfs_name=${OverlayFS%%,*}
        ;;
esac

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

{
    echo [Unit]
    echo Before=initrd-root-fs.target
    echo [Mount]
    echo Where=/sysroot
    getargbool 0 rd.overlayfs.readonly && readonly_overlay=--readonly
    basedirs=lowerdir="${readonly_overlay:+/run/overlayfs-r:}"/run/rootfsbase
    echo What="${ovlfs_name:=os_rootfs}"
    echo Options="${basedirs}",upperdir=/run/overlayfs,workdir=/run/ovlwork
    echo Type=overlay
} > "$GENERATOR_DIR"/sysroot.mount
ovlfs_name=$(echo "$ovlfs_name" | sed 's,/,\\x2f,g;s, ,\\x20,g;s,-,\\x2d,g;')

mkdir -p "$GENERATOR_DIR/$ovlfs_name".device.d
{
    echo [Unit]
    echo JobTimeoutSec=3000
    echo JobRunningTimeoutSec=3000
} > "$GENERATOR_DIR/$ovlfs_name".device.d/timeout.conf
