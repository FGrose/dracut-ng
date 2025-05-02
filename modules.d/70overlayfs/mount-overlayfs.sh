#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

OverlayFS=$(getarg rd.overlayfs) || exit 0

get_ovl_pt os_rootfs OverlayFS
[ "$OverlayFS" = off ] && exit 0

findmnt "${ovlfs_name:=os_rootfs}" > /dev/null 2>&1 || {
    [ -h /run/overlayfs ] && getargbool 0 rd.overlayfs.readonly \
        && readonly_overlay=--readonly

    basedirs=lowerdir="${readonly_overlay:+/run/overlayfs-r:}"/run/rootfsbase

    mount -t overlay "$ovlfs_name" \
        -o "$basedirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
}
