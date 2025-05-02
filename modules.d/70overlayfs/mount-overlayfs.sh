#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

OverlayFS=$(getarg rd.overlayfs) || exit 0
case "${OverlayFS%%[=/,]*}" in
    0 | no | off) exit 0 ;;
    '' | 1) ovlfs_name=os_rootfs ;;
    "${OverlayFS%%,*}") ovlfs_name=${OverlayFS%%,*} ;;
    *) # devspec present
        # with source name prefix
        [ "${OverlayFS%%,*}" != "$OverlayFS" ] && ovlfs_name=${OverlayFS%%,*}
        ;;
esac

findmnt "${ovlfs_name:=os_rootfs}" > /dev/null 2>&1 || {
    getargbool 0 rd.overlayfs.readonly && readonly_overlay=--readonly

    basedirs=lowerdir="${readonly_overlay:+/run/overlayfs-r:}"/run/rootfsbase

    mount -t overlay "$ovlfs_name" \
    -o "$basedirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
}
