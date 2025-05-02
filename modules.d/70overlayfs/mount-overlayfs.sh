#!/bin/sh

# Only proceed if prepare-overlayfs.sh has run and set up rootfsbase.
# This handles the case where root isn't available yet (e.g., network root like NFS).
# The script will be called again at pre-pivot when the root is mounted.
[ -e /run/rootfsbase ] || return 0

command -v getarg > /dev/null || . /lib/dracut-lib.sh

OverlayFS=$(getarg rd.overlay) || return 0

command -v get_ovl_pt > /dev/null || . /lib/overlayfs-lib.sh
volatile=volatile
get_ovl_pt "$OverlayFS" os_rootfs OverlayFS
[ "$OverlayFS" = off ] && return 0

findmnt "${ovlfs_name:=os_rootfs}" > /dev/null 2>&1 || {
    [ -h /run/overlayfs ] && getargbool 0 rd.overlay.readonly \
        && readonly_overlay=--readonly

    basedirs=lowerdir="${readonly_overlay:+/run/overlayfs-r:}"/run/rootfsbase

    mount -t overlay "$ovlfs_name" \
        -o "$basedirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
}
