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
root_pt="$1"
ln -s "$root_pt" /run/initramfs/root_pt

load_fstype overlay || die 'OverlayFS is required but unavailable.'

rd_overlayfs=$(getarg rd.overlayfs) && {
    case "${rd_overlayfs%%[=/,]*}" in
        0 | no | off) exit 1 ;;
        '' | 1) : ;;
        *)
            rd_overlayfs=${rd_overlayfs##*,}
            rd_overlayfs=${rd_overlayfs%%,*}
            ovl_pt=$(readlink -f "$(label_uuid_to_dev "${rd_overlayfs%%:*}")")
            ;;
    esac
    strstr "$rd_overlayfs" ":" && ovlpath=${rd_overlayfs##*:}
}

getargbool 0 rd.ovl.readonly && readonly_overlay=--readonly

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
    rflags=$rflags,ro
    mkdir -p /run/rootfsbase
    if [ "${DRACUT_SYSTEMD-}" ]; then
        # Repurpose rootfs-block/mount-root.sh for the base root partition.
        mntcmd=/sbin/mount-root
    else
        # Repurpose 99-mount-root.sh for the base root partition.
        mntcmd="$hookdir"/mount/99-mount-root.sh
    fi
    fstype="${root_ptfsType:-auto}" srcPartition="$root_pt" mountPoint=/run/rootfsbase srcflags="$rflags" "$mntcmd" override
    findmnt /run/rootfsbase > /dev/null 2>&1 || die "Unable to mount $root_pt."
else
    die "The root filesystem driver, $root_ptfsType, is unavailable."
fi

ovl_dir=$(getarg rd.ovl.dir) || ovl_dir=RootOvl

[ -b "$ovl_pt" ] && {
    mntDir=/run/initramfs/os_persist
    # Add an OverlayFS for persistent writes.
    do_overlayfs
}

ln -s null /dev/root

exit 0
