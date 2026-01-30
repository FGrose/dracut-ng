#!/bin/sh
# Runs as part of the dracut-pre-mount.service after any
#   non-virtual overlay partition is mounted.

command -v getarg > /dev/null || . /lib/dracut-lib.sh

OverlayFS=$(getarg rd.overlay -d rd.live.overlay.overlayfs) || return 0

command -v get_p_pt > /dev/null || . /lib/overlayfs-lib.sh
volatile=volatile
get_p_pt "$OverlayFS" os_rootfs OverlayFS
[ "$OverlayFS" = off ] && exit 0

if ! [ -e /run/rootfsbase ]; then
    # For legacy case of OverlayFS mount of non-live root block device.
    mkdir -m 0755 -p /run/rootfsbase
    mount --bind "$NEWROOT" /run/rootfsbase
fi

if [ "$p_pt" ]; then
    # Persistent overlays
    if getargbool 0 rd.overlay.reset; then
        ovlfsdir=$(readlink /run/overlayfs)
        info "Resetting the OverlayFS overlay directory."
        rm -r -- "${ovlfsdir:?}" > /dev/kmsg 2>&1
        mkdir -p "$ovlfsdir"
    fi
else
    # For temporary overlays:
    mount -m -t tmpfs os_tmp -o mode=0755${size:+,size="$size"} /run/ovl
    mkdir -m 0755 -p /run/ovl/upperdir /run/ovl/workdir
    ln -s /run/ovl/upperdir /run/overlayfs
    ln -s /run/ovl/workdir /run/ovlwork
fi
