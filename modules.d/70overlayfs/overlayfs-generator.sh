#!/bin/sh
type getarg > /dev/null 2>&1 || . /lib/dracut-lib.sh

[ "$root" ] || root=$(getarg root=)

getargbool 0 rd.overlayfs || exit 0

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
[ -z "$GENERATOR_DIR" ] && exit 1
[ -d "$GENERATOR_DIR" ] || mkdir -p "$GENERATOR_DIR"

load_fstype overlay && OverlayFS=ovl_rootfs
{
    echo "[Unit]"
    echo "Before=initrd-root-fs.target"
    echo "[Mount]"
    echo "Where=/sysroot"
    if [ "$OverlayFS" ]; then
        getargbool 0 rd.overlayfs.readonly && readonly_overlay="--readonly"
        basedirs=lowerdir="${readonly_overlay:+/run/overlayfs-r:}"/run/rootfsbase
        echo "What=$OverlayFS"
        echo "Options=${basedirs},upperdir=/run/overlayfs,workdir=/run/ovlwork"
        echo "Type=overlay"
        _dev="$OverlayFS"
    else
        die 'OverlayFS is required but unavailable.'
    fi
} > "$GENERATOR_DIR"/sysroot.mount

mkdir -p "$GENERATOR_DIR/$_dev.device.d"
{
    echo "[Unit]"
    echo "JobTimeoutSec=3000"
    echo "JobRunningTimeoutSec=3000"
} > "$GENERATOR_DIR/$_dev.device.d/timeout.conf"
