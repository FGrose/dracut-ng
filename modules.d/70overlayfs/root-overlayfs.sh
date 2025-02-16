#!/bin/sh

[ "$RD_DEBUG" = yes ] && set -x
if [ "$BASH" ]; then
    PS4='+ $(IFS=" " read -r u0 _ </proc/uptime; echo "$u0") $BASH_SOURCE@$LINENO ${FUNCNAME:+$FUNCNAME()}: '
else
    PS4='+ $0@$LINENO: '
fi
command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v det_fs > /dev/null || . /lib/fs-lib.sh
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

if load_fstype "$root_ptfsType"; then
    mkdir -p /run/rootfsbase
    ovl_dir=$(getarg rd.ovl.dir) || ovl_dir=RootOvl
    # Place overlays in a standard directory.
    ovl_dir=RootOverlays/"$ovl_dir"
    [ "${DRACUT_SYSTEMD-}" ] || {
        # Repurpose 99-mount-root.sh for the base root partition.
        fstype="${root_ptfsType:-auto}" srcPartition="$root_pt" \
            mountPoint=/run/rootfsbase srcflags="$rflags",ro fsckoptions="$fsckoptions" \
            "$hookdir"/mount/99-mount-root.sh override
        findmnt /run/rootfsbase || Die "Unable to mount $root_pt."
    }
else
    Die "The root filesystem driver, $root_ptfsType, is unavailable."
fi

[ "$volatile" ] || {
    [ -b "$ovl_pt" ] || Die "$ovl_pt is not available."

    mntDir=/run/os_persist
    # Add an OverlayFS for persistent writes.
    do_overlayfs
}

ln -s null /dev/root

exit 0
