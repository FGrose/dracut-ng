#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

getargbool 0 rd.overlayfs -d rd.live.overlay.overlayfs && OverlayFS="yes"
getargbool 0 rd.overlayfs.readonly -d rd.live.overlayfs.readonly && readonly_overlay="--readonly"

if [ -n "$OverlayFS" ]; then
    basedirs=lowerdir=${readonly_overlay:+/run/overlayfs-r:}/run/rootfsbase

    if ! strstr "$(cat /proc/mounts)" LiveOS_rootfs; then
        mount -t overlay LiveOS_rootfs -o "$basdirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
    fi
fi
