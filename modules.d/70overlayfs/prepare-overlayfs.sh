#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

getargbool 0 rd.overlayfs || return 0

if ! [ -e /run/rootfsbase ]; then
    mkdir -m 0755 -p /run/rootfsbase
    mount --bind "$NEWROOT" /run/rootfsbase
fi

[ -h /run/overlayfs ] || {
    # For temporary overlays:
    mkdir -m 0755 -p /run/overlayfs
    mkdir -m 0755 -p /run/ovlwork
}

if getargbool 0 rd.overlayfs.reset && [ -h /run/overlayfs ]; then
    ovlfsdir=$(readlink /run/overlayfs)
    info "Resetting the OverlayFS overlay directory."
    rm -r -- "${ovlfsdir:?}" > /dev/kmsg 2>&1
    mkdir -p "$ovlfsdir"
fi
