#!/bin/sh

[ "$RD_DEBUG" = yes ] && set -x
if [ "$BASH" ]; then
    PS4='+ $(IFS=" " read -r u0 _ </proc/uptime; echo "$u0") $BASH_SOURCE@$LINENO ${FUNCNAME:+$FUNCNAME()}: '
else
    PS4='+ $0@$LINENO: '
fi
command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v do_overlayfs > /dev/null || . /lib/overlayfs-lib.sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ "$1" ] || exit 1
ovl_pt=$(getarg rd.overlay) || exit 0
load_fstype overlay || die 'OverlayFS is required but unavailable.'

root_pt="$1"
get_ovl_pt os_rootfs ovl_pt
[ "$ovl_pt" = off ] && exit 0

strstr "$ovl_pt" ":" && ovlpath=${ovl_pt##*:}

devInfo=" $(get_devInfo "$root_pt")"
# Works for block devices or image files.
# missing tags will be skipped making order inconsistent between partitions.
root_ptfsType="${devInfo#*TYPE=\"}"
root_ptfsType="${root_ptfsType%%\"*}"
# Retrieve UUID, or if not present, PARTUUID.
uuid="${devInfo#*[ T]UUID=\"}"
uuid="${uuid%%\"*}"
label="${devInfo#* LABEL=\"}"
label="${label%%\"*}"

[ "$volatile" ] || {
    [ -b "$p_pt" ] || Die "$p_pt is not available."

    # Add a mount and directories for OverlayFS persistent writes.
    mntDir=/run/os_persist
    # Place overlays in a standard directory.
    ovl_dir=RootOverlays/"$ovl_dir"
    do_overlayfs
}

ln -sf "$root_pt" /run/initramfs/rorootfs
fstype="${root_ptfsType:-auto}" srcPartition="$root_pt" \
    mountPoint=/run/rootfsbase srcflags="$rflags",ro \
    fsckoptions="$fsckoptions" mount_partition
local dev mnt
ln -sf "$(while read -r dev mnt _; do [ "$mnt" = /run/rootfsbase ] \
    && {
        printf '%s\n' "$dev"
        break
    }; done < /proc/mounts)" /run/initramfs/rorootfs

ln -s null /dev/root

exit 0
