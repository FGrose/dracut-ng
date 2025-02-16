#!/bin/sh

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

[ "${DRACUT_SYSTEMD-}" ] \
    || load_fstype overlay \
    || Die 'OverlayFS is required but unavailable.'

rd_overlayfs=$(getarg rd.overlayfs) && {
    case "$rd_overlayfs" in
        0 | no | off) exit 1 ;;
    esac
    rd_overlayfs=${rd_overlayfs##*,}
    rd_overlayfs=${rd_overlayfs%%,*}
    ovl_pt=$(readlink -f "$(label_uuid_to_dev "${rd_overlayfs%%:*}")")

    if [ "${rd_overlayfs+zl}" = zl ]; then
        # Reuse rd.overlayfs as OverlayFS mount source name.
        etc_kernel_cmdline="$etc_kernel_cmdline rd.overlayfs=ovl_rootfs"
    elif strstr "$rd_overlayfs" ":"; then
        # ovlpath specified, extract
        ovlpath=${rd_overlayfs##*:}
    fi
}

getargbool 0 rd.ovl.readonly && readonly_overlay="--readonly"

# shellcheck disable=SC2046
devInfo="
$(blkid --probe --match-tag UUID -s LABEL -s TYPE --output export --usages filesystem "$root_pt")
"
# Works for block devices or image files.
# missing tags will be skipped making order inconsistent between partitions.
root_pt_fstype="${devInfo#*
TYPE=}"
root_pt_fstype="${root_pt_fstype%%
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

if load_fstype "$root_pt_fstype"; then
    rflags=$rflags,ro
    mkdir -p /run/rootfsbase
    # Repurpose 99-mount-root.sh for the base root partition.
    . "$hookdir"/mount/99-mount-root.sh
    fstype="${root_pt_fstype:-auto}" srcPartition="$root_pt" mountPoint=/run/rootfsbase srcflags="$rflags" mount_source
    findmnt /run/rootfsbase > /dev/null 2>&1 || Die "Unable to mount $root_pt."
else
    Die "The root filesystem driver, $root_pt_fstype, is unavailable."
fi

ovl_dir=$(getarg rd.ovl.dir) || ovl_dir=RootOvl
mntDir=/run/initramfs/os_persist
OverlayFS=os_persist

# Add an OverlayFS for persistent writes.
do_overlayfs

[ "$ETC_KERNEL_CMDLINE" ] && {
    mkdir -p /etc/kernel
    printf '%s' " $ETC_KERNEL_CMDLINE" >> /etc/kernel/cmdline
    [ "${DRACUT_SYSTEMD-}" ] && systemctl daemon-reload
}
[ "$etc_kernel_cmdline" ] && {
    # Adjust kernel cmdline without triggering systemctl daemon-reload.
    mkdir -p /etc/kernel
    printf '%s' " $etc_kernel_cmdline" >> /etc/kernel/cmdline
}

ln -s null /dev/root

exit 0
