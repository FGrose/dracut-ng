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
        fstype="${p_ptfsType:-auto}" srcPartition="$p_pt" \
            mountPoint=/run/initramfs/isoscan srcflags="$p_ptFlags" \
            override=override . "$mntcmd"
    else
        udevadm trigger --name-match="$devspec" --action=add --settle > /dev/null 2>&1
        mount -m -t auto -o ro "$devspec" /run/initramfs/isoscan || return 1
    fi
    ln -sf "$devspec" /run/initramfs/isoscandev
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
            dir="${dir#/}"
            set +x
            prompt_for_path "$message" /run/initramfs/isoscan/"${dir%/}" /run/initramfs/isoscan/"${dir%/}"/*.iso
            [ "$RD_DEBUG" = yes ] && set -x
            isofile="${objSelected#* \'}"
            isofile="${dir%/}/${isofile%\'}"
            # Remove link to diskDevice if set by prompt_for_device().
            rm /run/initramfs/diskdev > /dev/null 2>&1
            ;;
    esac
    _isofile=/run/initramfs/isoscan/"${isofile#/}"
    if [ -f "$_isofile" ]; then
        loopdev=$(losetup -f)
        losetup -rP "$loopdev" "$_isofile"
        udevadm trigger --name-match="$loopdev" --action=add --settle > /dev/null 2>&1
        ln -s "$_isofile" /run/initramfs/isofile
        ln -s "$loopdev" /run/initramfs/isoloop

        rm -f -- "$job"
        case "$isopath" in
            *PROMPT*)
                mount -m -n -t iso9660 -o ro "$loopdev"p1 /run/initramfs/live
                for bp in boot/x86_64/loader images/pxeboot isolinux; do
                    [ -d /run/initramfs/live/"$bp" ] && break
                done
                case "${bp##*/}" in
                    loader)
                        vm=linux
                        rd=initrd
                        ;;
                    pxeboot)
                        vm=vmlinuz
                        rd=initrd.img
                        ;;
                    isolinux)
                        vm=vmlinuz0
                        rd=initrd0.img
                        ;;
                esac
                read -r cmdline < /proc/cmdline
                cmdline="${cmdline#BOOT_IMAGE=* }"
                strstr "$cmdline" rd.live.image || cmdline="$cmdline rd.live.image"
                c1="${cmdline%iso-scan/filename=*}"
                c2="${cmdline#"${c1}"iso-scan/filename=}"
                c2="${c2#* }"
                cmdline="${c1}iso-scan/filename=UUID=${UUID}:${isofile} ${c2}"
                echo "/usr/sbin/dmsquash-live-root
/usr/sbin/iso-scan
/usr/bin/overlayfs-root_t.sh
/usr/bin/mount-root
/usr/bin/parted
/usr/lib/dracut-lib.sh
/usr/lib/dracut-lib-min.sh
/usr/lib/dracut-dev-lib.sh
/usr/lib/fs-lib.sh
/usr/lib/img-lib.sh
/usr/lib/partition-lib.sh
/usr/lib/partition-lib-min.sh
/usr/lib/overlayfs-lib.sh
/usr/lib/systemd/system-generators/dracut-dmsquash-generator
/usr/lib/systemd/system/overlayfs-root_t.service
/usr/lib64/libdevmapper.so.1.02
/usr/lib64/libparted.so.2
/usr/lib64/libparted.so.2.0.5
/var/
/var/lib/
/var/lib/dracut/
/var/lib/dracut/hooks/
/var/lib/dracut/hooks/cmdline/
/var/lib/dracut/hooks/cmdline/31-parse-iso-scan.sh
/var/lib/dracut/hooks/emergency/
/var/lib/dracut/hooks/initqueue/
/var/lib/dracut/hooks/initqueue/finished/
/var/lib/dracut/hooks/initqueue/online/
/var/lib/dracut/hooks/initqueue/settled/
/var/lib/dracut/hooks/initqueue/timeout/
/var/lib/dracut/hooks/mount/
/var/lib/dracut/hooks/netroot/
/var/lib/dracut/hooks/pre-mount/
/var/lib/dracut/hooks/pre-mount/01-prepare-overlayfs.sh
/var/lib/dracut/hooks/pre-pivot/
/var/lib/dracut/hooks/pre-pivot/51-overlayfs-pre-pivot-actions.sh
/var/lib/dracut/hooks/pre-pivot/52-dmsquash-live-pre-pivot-actions.sh
/var/lib/dracut/hooks/pre-shutdown/
/var/lib/dracut/hooks/pre-trigger/
/var/lib/dracut/hooks/pre-udev/
/var/lib/dracut/hooks/shutdown/
/var/lib/dracut/hooks/shutdown-emergency/
/lib/distribution-lib.sh" | cpio -o -H newc > /tmp/iso-scan.cpio
                cat /run/initramfs/live/"$bp/$rd" /tmp/iso-scan.cpio > /tmp/final.img
                kexec -d -s \
                    --load /run/initramfs/live/"$bp/$vm" \
                    --initrd /tmp/final.img \
                    --command-line "$cmdline"
                umount /run/initramfs/live
                losetup -d "$loopdev"
                umount "$devspec"
                kexec --exec
                ;;
        esac
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
        ptInfo=$(blkid "$pt_dev")
        LABEL="${ptInfo#* LABEL=\"}"
        LABEL="${LABEL%%\"*}"
        UUID="${ptInfo#* UUID=\"}"
        UUID="${UUID%%\"*}"
        devspec="$pt_dev"
    else
        command -v label_uuid_udevadm_trigger > /dev/null || . /lib/dracut-dev-lib.sh
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
