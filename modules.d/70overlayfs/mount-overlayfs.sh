#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

OverlayFS="$(getarg rd.overlayfs)" || return 0
case "$OverlayFS" in
    0 | no | off) return 0 ;;
esac

ismounted "$OverlayFS" || {
    getargbool 0 rd.overlayfs.readonly && readonly_overlay="--readonly"

    basedirs=lowerdir=${readonly_overlay:+/run/overlayfs-r:}/run/rootfsbase

    mount -t overlay "$OverlayFS" \
    -o "$basedirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
}
