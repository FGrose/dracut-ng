#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

getargbool 0 rd.overlayfs -d rd.live.overlay.overlayfs || return 0

ismounted LiveOS_rootfs || {
    getargbool 0 rd.overlayfs.readonly -d rd.live.overlayfs.readonly && readonly_overlay="--readonly"

    basedirs=lowerdir=${readonly_overlay:+/run/overlayfs-r:}/run/rootfsbase

    mount -t overlay LiveOS_rootfs -o "$basdirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
}
