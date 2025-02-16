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
ovl_pt=$(getarg rd.overlayfs) || exit 0
load_fstype overlay || Die 'OverlayFS is required but unavailable.'

root_pt="$1"
get_ovl_pt os_rootfs ovl_pt
[ "$ovl_pt" = off ] && exit 0

strstr "$ovl_pt" ":" && ovlpath=${ovl_pt##*:}

# shellcheck disable=SC2046
devInfo="
$(blkid --probe --match-tag UUID -s LABEL -s TYPE --output export --usages filesystem "$root_pt")
"
# Works for block devices or image files.
# missing tags will be skipped making order inconsistent between partitions.
root_ptfsType="${devInfo#*
TYPE=}"
root_ptfsType="${root_ptfsType%%
*}"
# Retrieve UUID, or if not present, PARTUUID.
uuid="${devInfo#*[
_]UUID=}"
uuid="${uuid%%
*}"
label="${devInfo#*
LABEL=}"
label="${label%%
*}"

[ "$volatile" ] || {
    [ -b "$ovl_pt" ] || Die "$ovl_pt is not available."

    # Add a mount and directories for OverlayFS persistent writes.
    mntDir=/run/os_persist
    ovl_dir=$(getarg rd.ovl.dir) || ovl_dir=RootOvl
    # Place overlays in a standard directory.
    ovl_dir=RootOverlays/"$ovl_dir"
    do_overlayfs
}

ln -sf "$root_pt" /run/initramfs/rorootfs
fstype="${root_ptfsType:-auto}" srcPartition="$root_pt" \
    mountPoint=/run/rootfsbase srcflags="$rflags",ro \
    fsckoptions="$fsckoptions" mount_partition
ln -sf "$(findmnt -no SOURCE /run/rootfsbase)" /run/initramfs/rorootfs

ln -s null /dev/root

exit 0
