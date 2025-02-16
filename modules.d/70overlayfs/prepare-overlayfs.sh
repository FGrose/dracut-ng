#!/bin/sh
# Runs as part of the dracut-pre-mount.service after any
#   non-virtual overlay partition is mounted.

command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v get_rd_overlay > /dev/null || . /lib/overlayfs-lib.sh

getargbool 0 rd.overlay -d rd.live.overlay.overlayfs || return 0

if ! [ -e /run/rootfsbase ]; then
    mkdir -m 0755 -p /run/rootfsbase
    mount --bind "$NEWROOT" /run/rootfsbase
fi

if [ -h /run/overlayfs ]; then
    # Persistent overlays
    if getargbool 0 rd.overlay.reset; then
        ovlfsdir=$(readlink /run/overlayfs)
        info "Resetting the OverlayFS overlay directory."
        rm -r -- "${ovlfsdir:?}" > /dev/kmsg 2>&1
        mkdir -p "$ovlfsdir"
    fi
else
    # For temporary overlays:
    mkdir -m 0755 -p /run/overlayfs /run/ovlwork
fi
