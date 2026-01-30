#!/bin/sh
# Runs as part of the dracut-pre-mount.service after any
#   non-virtual overlay partition is mounted.

[ -h /run/initramfs/p_pt ] || return 0

    # For legacy case of OverlayFS mount of non-live root block device.
[ -e /run/rootfsbase ] || mount -m --bind "$NEWROOT" /run/rootfsbase

if [ -b /run/initramfs/p_pt ]; then
    # Persistence partition
    [ -h /run/initramfs/reset_ovl ] && {
        ovlfsdir=$(readlink /run/overlayfs)
        info "Resetting the OverlayFS overlay directory."
        rm -r -- "${ovlfsdir:?}" > /dev/kmsg 2>&1
        mkdir -p "$ovlfsdir"
    }
else
    # For temporary overlays:
    mount -m -t tmpfs os_tmp -o mode=0755${size:+,size="$size"} /run/ovl
    mkdir -m 0755 -p /run/ovl/upperdir /run/ovl/workdir
    ln -s /run/ovl/upperdir /run/overlayfs
    ln -s /run/ovl/workdir /run/ovlwork
fi
