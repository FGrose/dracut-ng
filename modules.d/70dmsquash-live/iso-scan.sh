#!/bin/sh

[ "$RD_DEBUG" = yes ] && set -x
if [ "$BASH" ]; then
    PS4='+ $(IFS=" " read -r u0 _ </proc/uptime; echo "$u0") $BASH_SOURCE@$LINENO ${FUNCNAME:+$FUNCNAME()}: '
else
    PS4='+ $0@$LINENO: '
fi
command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v get_diskDevice > /dev/null || . /lib/partition-lib.sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

isopath=$1

[ "$isopath" ] || exit 1

ismounted "/run/initramfs/isoscan" && exit 0

isofile="${isopath##*:}"

rd_live_overlay=$(getarg rd.live.overlay) && {
    p_pt=${rd_live_overlay%%,*}
    p_pt=${p_pt##*,}
    p_pt=${p_pt%:*}
    [ "$p_pt" ] && p_pt=$(label_uuid_to_dev "$p_pt")
}

setup_isoloop() {
    mkdir -p /run/initramfs/isoscan
    if [ "$p_pt" -ef "$devspec" ]; then
        # Overlay and .iso source are on the same partition.
        command -v det_fs > /dev/null 2>&1 || . /lib/fs-lib.sh
        p_ptfsType=$(det_fs "$p_pt")
        command -v set_FS_opts_w > /dev/null || . /lib/distribution-lib.sh
        set_FS_opts_w "$p_ptfsType" p_ptFlags
        if [ "${DRACUT_SYSTEMD-}" ]; then
            # Repurpose rootfs-block/mount-root.sh for the persistence partition.
            mntcmd=/sbin/mount-root
        else
            # Repurpose 99-mount-root.sh for the overlay's & source partition.
            mntcmd="$hookdir"/mount/99-mount-root.sh
        fi
        fstype="${p_ptfsType:-auto}" srcPartition="$p_pt" mountPoint=/run/initramfs/isoscan srcflags="$p_ptFlags" "$mntcmd" override
    else
        mount -t auto -o ro "$devspec" /run/initramfs/isoscan || return 1
    fi
    case "$isofile" in
        PROMPTDR=*)
            dir=${isofile#PROMPTDR=}
            message="\`
\`            .iso image files from: $pt_dev ($LABEL) $dir
\`
\`           Select the file to be booted.
\`
"
            echo 'Press <Escape> to toggle menu, then Enter the # for your target here: ' > /tmp/prompt
            prompt_for_path "$message" /run/initramfs/isoscan/"${dir%/}" /run/initramfs/isoscan/"${dir%/}"/*.iso
            isofile="${objSelected#* \'}"
            isofile="${dir%/}/${isofile%\'}"
            # Remove link to diskDevice if set by prompt_for_device().
            rm /run/initramfs/diskdev > /dev/null 2>&1
            ;;
    esac
    isofile=/run/initramfs/isoscan/"${isofile#/}"
    if [ -f "$isofile" ]; then
        loopdev=$(losetup -f)
        losetup -rP "$loopdev" "$isofile"
        udevadm trigger --name-match="$loopdev" --action=add --settle > /dev/null 2>&1
        ln -s "$loopdev" /run/initramfs/isoloop
        ln -s "$isofile" /run/initramfs/isofile
        ln -s "$devspec" /run/initramfs/isoscandev
        rm -f -- "$job"
        exit 0
    else
        umount /run/initramfs/isoscan
    fi
}

strstr "${isopath}" ":" && {
    devspec="${isopath%%:*}"
    if [ "$devspec" = PROMPTPT ]; then
        sleep 0.5
        udevadm trigger --subsystem-match block --settle
        # Assign devspec.
        message='
`
`               Select the partition that holds your .iso files.
`'
        prompt_for_device PT "$message" warn0
        devspec="$pt_dev"
        LABEL=$(blkid "$pt_dev")
        LABEL="${LABEL#* LABEL=\"}"
        LABEL="${LABEL%%\"*}"
    else
        label_uuid_udevadm_trigger "$devspec"
        devspec=$(readlink -f "$(label_uuid_to_dev "$devspec")")
    fi
    i=0
    until [ -e "$devspec" ] || [ "$i" -eq 20 ]; do
        sleep 0.5
        i=$((i + 1))
    done
    setup_isoloop || Die "$devspec & $isofile could not be setup."
}

do_iso_scan() {
    local _name
    for devspec in /dev/disk/by-uuid/*; do
        _name=$(dev_unit_name "$devspec")
        [ -e /tmp/isoscan-"${_name}" ] && continue
        : > /tmp/isoscan-"${_name}"
        setup_isoloop || continue
    done
}

[ "$loopdev" ] || do_iso_scan

rmdir "/run/initramfs/isoscan"
exit 1
