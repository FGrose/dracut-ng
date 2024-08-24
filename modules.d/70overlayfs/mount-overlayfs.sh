#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

# Only proceed if prepare-overlayfs.sh has run and set up rootfsbase.
# This handles the case where root isn't available yet (e.g., network root like NFS).
# The script will be called again at pre-pivot when the root is mounted.
[ -e /run/rootfsbase ] || return 0

getargbool 0 rd.overlayfs -d rd.live.overlay.overlayfs || return 0

basedirs=lowerdir=${readonly_overlay:+/run/overlayfs-r:}/run/rootfsbase

strstr "$(cat /proc/mounts)" LiveOS_rootfs \
    || mount -t overlay LiveOS_rootfs -o "$ROOTFLAGS,$basdirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
