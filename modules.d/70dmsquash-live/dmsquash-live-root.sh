#!/bin/sh

[ "$RD_DEBUG" = yes ] && set -x
if [ "$BASH" ]; then
    PS4='+ $(IFS=" " read -r u0 _ </proc/uptime; echo "$u0") $BASH_SOURCE@$LINENO ${FUNCNAME:+$FUNCNAME()}: '
else
    PS4='+ $0@$LINENO: '
fi
command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v det_fs > /dev/null || . /lib/fs-lib.sh
command -v unpack_archive > /dev/null || . /lib/img-lib.sh
command -v do_overlayfs > /dev/null || . /lib/overlayfs-lib.sh
. /lib/partition-lib.sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ "$1" ] || exit 1
livedev="$1"
ln -s "$livedev" /run/initramfs/livedev

# Determine some attributes for the device - $1
get_diskDevice() {
    local - dev n syspath p_path
    set -x
    dev="${1##*/}"
    syspath=/sys/class/block/"$dev"
    n=0
    until [ -d "$syspath" ] || [ "$n" -gt 9 ]; do
        sleep 0.4
        n=$((n + 1))
    done
    [ -d "$syspath" ] || return 1
    if [ -f "$syspath"/partition ]; then
        p_path=$(readlink -f "$syspath"/..)
        diskDevice=/dev/"${p_path##*/}"
    else
        while read -r line; do
            case "$line" in
                DEVTYPE=disk) diskDevice=/dev/"$dev" ;;
                DEVTYPE=loop) return 0 ;;
            esac
        done < "$syspath"/uevent
    fi
    { read -r optimalIO < "$syspath"/queue/optimal_io_size; } > /dev/null 2>&1
    : "${optimalIO:=0}"
    fsType=$(blkid /dev/"$dev")
    fsType="${fsType#* TYPE=\"}"
    fsType="${fsType%%\"*}"
    ln -sf "$diskDevice" /run/initramfs/diskdev
}

[ -f "$livedev" ] || get_diskDevice "$livedev"

devInfo=" $(get_devInfo "$livedev")"
# The above works for block devices or image files.
# Missing tags will be skipped, making order inconsistent between partitions.
livedev_fstype="${devInfo#*TYPE=\"}"
livedev_fstype="${livedev_fstype%%\"*}"
# Retrieve UUID, or if not present, PARTUUID.
uuid="${devInfo#*[ T]UUID=\"}"
uuid="${uuid%%\"*}"
label="${devInfo#*LABEL=\"}"
label="${label%%\"*}"

load_fstype "$livedev_fstype"
live_dir=$(getarg rd.live.dir) || live_dir=LiveOS
roroot_image=$(getarg rd.live.rorootimg -d -y rd.live.squashimg) || roroot_image=squashfs.img
getargbool 0 rd.live.ram && live_ram=yes
getargbool 0 rd.overlay.reset -d -y rd.live.overlay.reset && {
    reset_overlay=yes
    etc_kernel_cmdline="$etc_kernel_cmdline rd.overlay.reset"
}
getargbool 0 rd.overlay.readonly -d -y rd.live.overlay.readonly && {
    readonly_overlay=--readonly
    etc_kernel_cmdline="$etc_kernel_cmdline rd.overlay.readonly"
}
getargbool 0 rd.writable.fsimg && writable_fsimg=yes
overlay_size=$(getarg rd.live.overlay.size=) || overlay_size=32768
getargbool 0 rd.live.overlay.thin && thin_snapshot=yes
OverlayFS=$(getarg rd.overlay -d -y rd.live.overlay.overlayfs) && {
    case "$OverlayFS" in
        '') OverlayFS=1 ;;
        0 | no | off) unset -v 'OverlayFS' ;;
    esac
}
[ "${DRACUT_SYSTEMD-}" ] || {
    # Check for kernel overlay module
    load_fstype overlay || {
        [ "$OverlayFS" ] && {
            unset -v 'OverlayFS'
            etc_kernel_cmdline="$etc_kernel_cmdline rd.overlay=0"
        }
    }
}

# CD/DVD/USB media check
rd_live_check() {
    local - check_dev="$1"
    set +x
    getargbool 0 rd.live.check && {
        type plymouth > /dev/null 2>&1 && plymouth --hide-splash
        if [ "${DRACUT_SYSTEMD-}" ]; then
            systemctl start checkisomd5@"$(dev_unit_name "$check_dev")".service
        else
            checkisomd5 --verbose "$check_dev"
        fi
        # Allow user interrupted check, which returns exit code 2.
        if [ $? -eq 1 ]; then
            warn "Media check failed! We do not recommend using this medium. System will halt in 12 hours."
            sleep 43200
            die "Media check failed!"
            exit 1
        fi
        type plymouth > /dev/null 2>&1 && plymouth --show-splash
    }
}

rd_overlay=$(get_rd_overlay) && {
    IFS=, parse_cfgArgs "$rd_overlay"

    # Set default ovlpath, if not specified.
    [ "$ovlpath" = auto ] && unset -v 'ovlpath'
    : "${ovlpath:=/"$live_dir"/overlay-"$label"-"$uuid"}"
    str_starts "$ovlpath" '/' || ovlpath=/"$ovlpath"
}

case "$livedev_fstype" in
    iso9660 | udf)
        rd_live_check "${diskDevice:-$livedev}"
        srcdir=LiveOS
        liverw=ro
        [ -h /run/initramfs/p_pt ] && [ ! "$removePt" ] || {
            [ "$rd_overlay" ] && prep_Partition
        }
        ;;
    *)
        srcdir=${live_dir:=LiveOS}
        liverw=rw
        ;;
esac

[ "$partitionTable" ] || get_partitionTable "$diskDevice"

# mount the backing of the live image first
mkdir -m 0755 -p /run/initramfs/live
case "$livedev_fstype" in
    auto)
        die "cannot mount live image (unknown filesystem type $livedev_fstype)"
        ;;
    iso9660)
        [ -f "$livedev" ] && {
            loopdev=$(losetup -f)
            losetup -rP "$loopdev" "$livedev"
            udevadm trigger --name-match="$loopdev" --action=add --settle > /dev/null 2>&1
            ln -s "$loopdev" /run/initramfs/isoloop
            ln -s "$livedev" /run/initramfs/isofile
            livedev=$loopdev
        }
        mntcmd="mount -n -t $livedev_fstype"
        ;;
    squashfs | erofs)
        # no mount needed - we've already got the LiveOS image in $livedev
        ROROOTFS=$livedev
        ;;
    ntfs)
        [ -x /sbin/mount-ntfs-3g ] && mntcmd=/sbin/mount-ntfs-3g
        ;;
    *)
        if [ -f "$livedev" ]; then
            FSIMG=$livedev
        else
            mntcmd="mount -n -t $livedev_fstype"
        fi
        ;;
esac
[ "${mntcmd+mount}" ] && {
    # workaround some timing problem
    sleep 0.1
    $mntcmd -o ${liverw:-ro} "$livedev" /run/initramfs/live > /dev/kmsg 2>&1 \
        || die "Failed to mount block device of live image."
}

# overlay setup helper function
do_live_overlay() {
    # need to know where to look for the overlay
    if [ ! "$setup" ] && [ "$p_Partition" ] && [ "$ovlpath" ]; then
        mkdir -m 0755 -p "${mntDir:=/run/LiveOS_persist}"
        # Find final mount point for the partition.
        set -- "$(tac /proc/mounts | while read -r src mnt _ _; do
            [ "$src" = "$p_Partition" ] && echo "$mnt" && break
        done)"
        if [ "$1" ]; then
            [ "$1" = "$mntDir" ] || mount --bind "$1" "$mntDir"
            # We need $p_Partition writable for persistent overlay storage.
            [ ! -w "$mntDir" ] && [ ! "$readonly_overlay" ] && mount -o remount,rw "$mntDir"
        else
            ovl_pt=$p_Partition
            ovl_dir="$live_dir"
            [ "$p_ptFlags" ] || set_FS_opts_w "${p_ptfsType:=$(det_fs "$ovl_pt")}" p_ptFlags
            mount_partition
        fi
        if [ -f "$mntDir$ovlpath" ] && [ -w "$mntDir$ovlpath" ]; then
            local OVERLAY_LOOPDEV over
            OVERLAY_LOOPDEV=$(losetup -f)
            losetup ${readonly_overlay:+-r} "$OVERLAY_LOOPDEV" "$mntDir$ovlpath"
            umount -l "$mntDir" || :
            ovl_fstype="$(det_fs "$OVERLAY_LOOPDEV")"
            case "$ovl_fstype" in
                # (Uninitialized DM_snapshot_cow returns ''.)
                '' | DM_snapshot_cow)
                    ## Device-mapper overlay
                    [ "$reset_overlay" ] && {
                        info "Resetting the Device-mapper overlay."
                        dd if=/dev/zero of="$OVERLAY_LOOPDEV" bs=64k count=1 conv=fsync 2> /dev/null
                    }
                    [ "$OverlayFS" ] && {
                        # Override incorrect configuration:
                        ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=0"
                        unset -v 'OverlayFS'
                    }
                    setup=setup
                    ;;
                *)
                    ## OverlayFS embedded in an image file (needed with vfat formatted devices).
                    p_Partition=$OVERLAY_LOOPDEV
                    # This leads to an overmount of $mntDir in /sbin/do-overlay
                    ovlpath=/overlayfs
                    live_dir=''
                    [ "$OverlayFS" ] || ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=LiveOS_rootfs"
                    setup=setup
                    ;;
            esac
        elif [ -d "$mntDir$ovlpath" ] && [ -d "$mntDir$ovlpath"/../ovlwork ]; then
            ## OverlayFS on xattr-enabled filesystem.
            [ "$OverlayFS" ] || ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=LiveOS_root"
            setup=setup
        fi
    fi

    if [ ! "$setup" ] || [ "$readonly_overlay" ]; then
        if [ "$setup" ]; then
            info "Using a temporary overlay."
        elif [ "$p_Partition" ] && [ "$ovlpath" ]; then
            prompt_message \
                '   Unable to find a persistent overlay; using a temporary one.' \
                '  All root filesystem changes will be lost on shutdown.' \
                '  Press [Enter] to continue.'
        fi
        [ "$OverlayFS" ] || {
            dd if=/dev/null of=/overlay bs=1024 count=1 seek=$((overlay_size * 1024)) 2> /dev/null
            if [ "$setup" ] && [ "$readonly_overlay" ]; then
                RO_OVERLAY_LOOPDEV=$(losetup -f)
                losetup "$RO_OVERLAY_LOOPDEV" /overlay
                over=$RO_OVERLAY_LOOPDEV
            else
                OVERLAY_LOOPDEV=$(losetup -f)
                losetup "$OVERLAY_LOOPDEV" /overlay
                over=$OVERLAY_LOOPDEV
            fi
        }
    fi

    # set up the snapshot
    [ "$OverlayFS" ] || {
        if [ "$readonly_overlay" ] && [ "$OVERLAY_LOOPDEV" ]; then
            echo 0 "$sz" snapshot "$BASE_LOOPDEV" "$OVERLAY_LOOPDEV" P 8 | dmsetup create --readonly live-ro
            base=/dev/mapper/live-ro
        else
            base=$BASE_LOOPDEV
        fi
        if [ "$thin_snapshot" ]; then
            modprobe dm_thin_pool
            mkdir -m 0755 -p /run/initramfs/thin-overlay

            # In block units (512b)
            thin_data_sz=$((overlay_size * 1024 * 1024 / 512))
            thin_meta_sz=$((thin_data_sz / 10))

            # It is important to have the backing file on a tmpfs
            # this is needed to let the loopdevice support TRIM
            dd if=/dev/null of=/run/initramfs/thin-overlay/meta bs=1b count=1 seek=$((thin_meta_sz)) 2> /dev/null
            dd if=/dev/null of=/run/initramfs/thin-overlay/data bs=1b count=1 seek=$((thin_data_sz)) 2> /dev/null

            THIN_META_LOOPDEV=$(losetup -f)
            losetup "$THIN_META_LOOPDEV" /run/initramfs/thin-overlay/meta
            THIN_DATA_LOOPDEV=$(losetup -f)
            losetup "$THIN_DATA_LOOPDEV" /run/initramfs/thin-overlay/data

            echo 0 $thin_data_sz thin-pool "$THIN_META_LOOPDEV" "$THIN_DATA_LOOPDEV" 1024 1024 | dmsetup create live-overlay-pool
            dmsetup message /dev/mapper/live-overlay-pool 0 "create_thin 0"

            # Create a snapshot of the base image
            echo 0 "$thin_data_sz" thin /dev/mapper/live-overlay-pool 0 "$base" | dmsetup create live-rw
        else
            echo 0 "$sz" snapshot "$base" "$over" PO 8 | dmsetup create live-rw
        fi
        # Create a device for the ro base of dm overlaid file systems.
        echo 0 "$sz" linear "$BASE_LOOPDEV" 0 | dmsetup create --readonly live-base
    }

    ln -s "$BASE_LOOPDEV" /dev/live-base
}
# end do_live_overlay()

# we might have an embedded fs image on squashfs (compressed live)
#   Source may be a mounted .iso image, an installed LiveUSB, or a link to an image partition.
for FSIMG in "$roroot_image" rorootfs.img rootfs.img ext3fs.img; do
    FSIMG=/run/initramfs/live/"$srcdir/$FSIMG"
    [ -e "$FSIMG" ] && break
done
if [ -e "$SQUASHED" ]; then
    if [ "$live_ram" ]; then
        imgsize=$(($(blkid --probe --match-tag FSSIZE --output value --usages filesystem "$SQUASHED") / (1024 * 1024)))
        check_live_ram $imgsize
        echo 'Copying live image to RAM...' > /dev/kmsg
        echo ' (this may take a minute)' > /dev/kmsg
        dd if="$SQUASHED" of=/run/initramfs/squashed.img bs=512 2> /dev/null
        echo 'Done copying live image to RAM.' > /dev/kmsg
        SQUASHED=/run/initramfs/squashed.img
    fi

    SQUASHED_LOOPDEV=$(losetup -f)
    losetup -r "$SQUASHED_LOOPDEV" "$SQUASHED"
    mkdir -m 0755 -p /run/initramfs/squashfs
    mount -n -o ro "$SQUASHED_LOOPDEV" /run/initramfs/squashfs

    if [ -d /run/initramfs/squashfs/LiveOS ]; then
        if [ -f /run/initramfs/squashfs/LiveOS/rootfs.img ]; then
            FSIMG=/run/initramfs/squashfs/LiveOS/rootfs.img
        fi
    elif [ -d /run/initramfs/squashfs/usr ] || [ -d /run/initramfs/squashfs/ostree ]; then
        FSIMG=$SQUASHED
        # If needed, adjust OverlayFS,
        # or die if OverlayFS is required but unavailable.
        if [ -d /sys/module/overlay ]; then
            [ "$OverlayFS" ] || {
                OverlayFS=LiveOS_rootfs
                ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=LiveOS_rootfs"
            }
        else
            die 'OverlayFS is required but unavailable.'
            exit 1
        fi
    else
        die "Failed to find a root filesystem in $SQUASHED."
        exit 1
    fi
else
    # we might have an embedded fs image to use as rootfs (uncompressed live)
    if [ -e /run/initramfs/live/"$srcdir"/rootfs.img ]; then
        FSIMG=/run/initramfs/live/"$srcdir"/rootfs.img
    fi
    if [ "$live_ram" ]; then
        echo 'Copying live image to RAM...' > /dev/kmsg
        echo ' (this may take a minute or so)' > /dev/kmsg
        dd if="$FSIMG" of=/run/initramfs/rootfs.img bs=512 2> /dev/null
        echo 'Done copying live image to RAM.' > /dev/kmsg
        FSIMG=/run/initramfs/rootfs.img
    fi
fi

if [ "$FSIMG" ]; then
    if [ "$writable_fsimg" ]; then
        # mount the provided filesystem read/write
        echo "Unpacking live filesystem (may take some time)" > /dev/kmsg
        mkdir -m 0755 -p /run/initramfs/fsimg/
        if [ "$SQUASHED" ]; then
            cp -v "$FSIMG" /run/initramfs/fsimg/rootfs.img
        else
            unpack_archive "$FSIMG" /run/initramfs/fsimg/
        fi
        FSIMG=/run/initramfs/fsimg/rootfs.img
    fi
    # For writable DM images...
    readonly_base=1
    if [ ! "$SQUASHED" ] && [ "$live_ram" ] && [ ! "$OverlayFS" ] \
        || [ "$writable_fsimg" ] \
        || [ "$rd_overlay" = none ] || [ "$rd_overlay" = None ] || [ "$rd_overlay" = NONE ]; then
        if [ ! "$readonly_overlay" ]; then
            unset readonly_base
            setup=rw
        else
            setup=setup
        fi
    fi
    if [ "$FSIMG" = "$SQUASHED" ]; then
        BASE_LOOPDEV=$SQUASHED_LOOPDEV
    else
        BASE_LOOPDEV=$(losetup -f)
        losetup ${readonly_base:+-r} "$BASE_LOOPDEV" "$FSIMG"
        sz=$(cat /sys/class/block/"${BASE_LOOPDEV##*/}"/size)
    fi
    if [ "$setup" = rw ]; then
        echo 0 "$sz" linear "$BASE_LOOPDEV" 0 | dmsetup create live-rw
    else
        # Add a DM snapshot for writes or begin setup of OverlayFS.
        do_live_overlay
    fi
fi

if [ "$OverlayFS" ]; then
    if [ "$FSIMG" ]; then
        mkdir -m 0755 -p /run/rootfsbase
        if [ "$FSIMG" = "$SQUASHED" ]; then
            mount --bind /run/initramfs/squashfs /run/rootfsbase
        elif [ "${DRACUT_SYSTEMD-}" ]; then
            ln -s "$FSIMG" /run/initramfs/rorootdev
            systemctl start run-rootfsbase.mount
        else
            srcPartition="$FSIMG" srcflags=,ro mountPoint=/run/rootfsbase \
                override=override . "$hookdir"/mount/99-mount-root.sh
        fi
        # Reuse variable to hold OverlayFS mount source name.
        rd_overlay=LiveOS_rootfs
    else
        [ -d /sys/module/overlay ] || die 'OverlayFS is required but unavailable.'
        # Support legacy case of OverlayFS over traditional root block device.
        ln -sf /run/initramfs/live /run/rootfsbase
        rd_overlay=os_rootfs
    fi
    # From rd.live.overlay.overlayfs=1 case
    [ "$OverlayFS" = 1 ] && {
        OverlayFS="$rd_overlay"
        etc_kernel_cmdline="$etc_kernel_cmdline rd.overlay=$rd_overlay"
    }
    ovl_pt=$p_Partition
    ovl_dir="$live_dir"
    # Add an OverlayFS for persistent writes.
    do_overlayfs
else
    [ "${DRACUT_SYSTEMD-}" ] || {
        printf 'mount %s /dev/mapper/live-rw %s\n' "${rflags:+-o $rflags}" "$NEWROOT" > "$hookdir"/mount/01-$$-live.sh
    }
fi
[ -e "$SQUASHED" ] && umount -l /run/initramfs/squashfs

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

need_shutdown

exit 0
