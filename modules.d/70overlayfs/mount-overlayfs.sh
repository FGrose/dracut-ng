#!/bin/sh

# Only proceed if prepare-overlayfs.sh has run and set up rootfsbase.
# This handles the case where root isn't available yet (e.g., network root like NFS).
# The script will be called again at pre-pivot when the root is mounted.
[ -e /run/rootfsbase ] || return 0
[ -h /run/initramfs/p_pt ] || return 0
[ -d /run/ovl/upperdir ] && volatile=volatile
ovlfs_name=$(readlink /run/initramfs/ovlfs)

findmnt "${ovlfs_name:=os_rootfs}" > /dev/null 2>&1 || {
    [ -b /run/initramfs/p_pt ] && [ -h /run/initramfs/ro_ovl ] && {
        readonly_overlay=--readonly
        volatile=volatile
    }

    basedirs=lowerdir="${readonly_overlay:+/run/overlayfs-r:}"/run/rootfsbase

    mount -t overlay "$ovlfs_name" \
        -o "${volatile:+volatile,}$basedirs",upperdir=/run/overlayfs,workdir=/run/ovlwork "$NEWROOT"
}
