#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

# Only proceed if prepare-overlayfs.sh has run and set up rootfsbase.
# This handles the case where root isn't available yet (e.g., network root like NFS).
# The script will be called again at pre-pivot when the root is mounted.
[ -e /run/rootfsbase ] || return 0

getargbool 0 rd.overlayfs -d rd.live.overlay.overlayfs || return 0

if [ -n "$readonly_overlay" ] && [ -h /run/overlayfs-r ]; then
    ovlfs=lowerdir=/run/overlayfs-r:/run/rootfsbase
else
    ovlfs=lowerdir=/run/rootfsbase
fi

if ! strstr "$(cat /proc/mounts)" LiveOS_rootfs; then
    mount -t overlay LiveOS_rootfs -o "$ovlfs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
fi
