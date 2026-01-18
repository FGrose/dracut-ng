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
command -v get_diskDevice > /dev/null || . /lib/partition-lib.sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Avoid re-triggering these rules.
rm -- /etc/udev/rules.d/99-live-squash.rules \
    /etc/udev/rules.d/99-liveiso-mount.rules > /dev/null 2>&1
udevadm control --reload

[ "$1" ] || exit 1
livedev="$1"
ln -s "$livedev" /run/initramfs/livedev

# shellcheck disable=SC2046
devInfo="
$(blkid --probe --match-tag UUID -s PART_ENTRY_UUID -s PART_ENTRY_NAME -s LABEL -s TYPE --output export --usages filesystem "$livedev")
"
# The above works for block devices or image files.
# Missing tags will be skipped, making order inconsistent between partitions.
livedev_fstype="${devInfo#*
TYPE=}"
livedev_fstype="${livedev_fstype%%
*}"
# Retrieve UUID, or if not present, PART_ENTRY_UUID.
uuid="${devInfo#*[
_]UUID=}"
uuid="${uuid%%
*}"
partuuid="${devInfo#*
PART_ENTRY_UUID=}"
partuuid="${partuuid%%
*}"
label="${devInfo#*
LABEL=}"
label="${label%%
*}"
partName="${devInfo#*
PART_ENTRY_NAME=}"
partName="${partName%%
*}"

ln -sf "$uuid" /run/initramfs/live_uuid
ln -sf "$partuuid" /run/initramfs/live_partuuid
load_fstype "$livedev_fstype"
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
    local - check_dev=$1
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
            Die "Media check failed!"
            exit 1
        fi
        type plymouth > /dev/null 2>&1 && plymouth --show-splash
    }
}

if [ -h /run/initramfs/diskdev ]; then
    get_diskDevice "$(readlink -f /run/initramfs/diskdev)"
elif [ ! -f "$livedev" ]; then
    get_diskDevice "$livedev"
fi

case "$livedev_fstype" in
    iso9660 | udf)
        rd_live_check "${diskDevice:-$livedev}"
        srcdir=LiveOS
        liverw=ro
        ;;
    *)
        srcdir=${ovl_dir:=LiveOS}
        liverw=rw
        ;;
esac

rd_live_image=$(getarg rd.live.image) && {
    IFS=, parse_cfgArgs img,"$rd_live_image"
    [ "$p_pt" ] && unset -v 'p_pt'
    #  Case where partition specification is used for disk specification.
}

ovl_dir=$(getarg rd.ovl.dir -d rd.live.dir) || ovl_dir=LiveOS
[ "$ovl_dir" = PROMPT ] && prompt_for_livedir
ln -sf "$ovl_dir" /run/initramfs/ovl_dir

[ "$partitionTable" ] || get_partitionTable "$diskDevice"

rd_overlay=$(getarg rd.overlay -d rd.live.overlay) && {
    IFS=, parse_cfgArgs ovl,"$rd_overlay"

    [ "$p_pt" ] && {
        # Set default ovlpath, if not specified.
        [ "$ovlpath" = auto ] && unset -v 'ovlpath'
        : "${ovlpath:=/"$ovl_dir/overlay-$label-$uuid"}"
        str_starts "$ovlpath" '/' || ovlpath=/"$ovlpath"
    }
}

if [ "$removePt$p_pt$cfg" ]; then
    prep_Partition
fi

case "$cfg" in
    ciso)
        [ "$OverlayFS" ] || ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=${OverlayFS:=LiveOS_rootfs}"
        set_FS_opts "$fsType" p_ptFlags
        ovl_dir="$ovl_dir"
        ln -sf "$p_pt" /run/initramfs/p_pt
        fstype="${p_ptfsType:-auto}" srcPartition="$p_pt" \
            mountPoint="$mntDir" srcflags="$p_ptFlags" fsckoptions="$fsckoptions" \
            mount_partition
        install_Image
        ;;
    ropt)
        loopdev=$(losetup -P -r -f --show /run/initramfs/isofile)
        livedev="${loopdev}p1"
        ;;
esac

# mount the backing of the live image
mkdir -m 0755 -p /run/initramfs/live
case "$livedev_fstype" in
    auto)
        Die "cannot mount live image (unknown filesystem type $livedev_fstype)"
        ;;
    iso9660)
        [ -f "$livedev" ] && {
            loopdev=$(losetup -P -r -f --show "$livedev")
            udevadm trigger --name-match="$loopdev" --action=add --settle > /dev/null 2>&1
            ln -s "$loopdev" /run/initramfs/isoloop
            ln -s "$livedev" /run/initramfs/isofile
            livedev=$loopdev
        }
        mntcmd="mount -n -t $livedev_fstype"
        ;;
    squashfs | erofs)
        # no mount needed - we've already got the LiveOS image in $livedev
        FSIMG=$livedev
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
        || Die "Failed to mount block device of live image."
}

[ "$espStart$base_dir$cfg" ] && {
    # New installations...
    [ "$ESP" ] || get_ESP "$diskDevice"

    # Copy content for new BOOTPATH.
    mount -n -m -t vfat -o check=s /run/initramfs/espdev /run/initramfs/ESP

    mkdir -p "${BOOTPATH:=/run/initramfs/ESP/"$ovl_dir"}"
    GRUB_cfg=/run/initramfs/ESP/EFI/BOOT/grub.cfg

    # Save a previous configuration, if present.
    set -- /run/initramfs/ESP/*/images /run/initramfs/ESP/*/boot
    [ -e "$1" ] || [ -e "$2" ] && {
        cp -a "$GRUB_cfg" "$GRUB_cfg".multi
        cp -a "$GRUB_cfg".multi "$GRUB_cfg".prev
        [ "$base_dir" ] && {
            [ -d /run/initramfs/ESP/"$base_dir" ] || {
                [ -e "$1" ] || shift
                # Fix bug in GRUB that misreports first directory name.
                base_dir=${1#*ESP/}
                base_dir=${base_dir%/*}
            }
        }
    }

    BOOTDIR=boot
    [ -d /run/initramfs/live/images/pxeboot ] && BOOTDIR=images

    mkdir -p "${BOOTPATH:=/run/initramfs/ESP/"$ovl_dir"}"
    if [ "$base_dir" ]; then
        cfg=ovl
        cp -au /run/initramfs/ESP/"$base_dir/$BOOTDIR" "$BOOTPATH" || Die "Copy of $base_dir/$BOOTDIR to $BOOTPATH failed."
        # Trigger update_BootConfig in pre-pivot-actions.sh
        rm "$BOOTPATH"/esp_uuid
    else
        cp -au /run/initramfs/live/"$BOOTDIR" "$BOOTPATH" || Die "Copy to $BOOTPATH failed."
    fi
    # cp -u preserves files with newer modification timestamps.
    cp -au /run/initramfs/live/EFI /run/initramfs/ESP || Die "Copy to ${BOOTPATH%/*} failed."

    cp /run/initramfs/live/boot/grub2/grub.cfg "$GRUB_cfg"

    [ -d /run/initramfs/live/System ] && {
        cp -au /run/initramfs/live/System /run/initramfs/ESP
        cp -au /run/initramfs/live/mach_kernel /run/initramfs/ESP
    }
    printf '%s' "$cfg" > /run/initramfs/cfg
}

# overlay setup helper function
do_live_overlay() {
    # need to know where to look for the overlay
    if [ ! "$setup" ] && [ "$p_pt" ] && [ "$ovlpath" ]; then
        mkdir -m 0755 -p "${mntDir:=/run/LiveOS_persist}"
        set -- "$(findmnt -d backward -fnro TARGET "$p_pt")"
        if [ "$1" ]; then
            [ "$1" = "$mntDir" ] || mount --bind "$1" "$mntDir"
            # We need $p_pt writable for persistent overlay storage.
            [ ! -w "$mntDir" ] && [ ! "$readonly_overlay" ] && mount -o remount,rw "$mntDir"
        else
            ovl_dir="$ovl_dir"
            [ "$p_ptFlags" ] || set_FS_opts "${p_ptfsType:=$(blkid --probe --match-tag TYPE --output value --usages filesystem "$p_pt")}" p_ptFlags
            ln -sf "$p_pt" /run/initramfs/p_pt
            fstype="${p_ptfsType:-auto}" srcPartition="$p_pt" \
                mountPoint="$mntDir" srcflags="$p_ptFlags" fsckoptions="$fsckoptions" \
                mount_partition
        fi
        if [ -f "$mntDir$ovlpath" ] && [ -w "$mntDir$ovlpath" ]; then
            local OVERLAY_LOOPDEV over
            OVERLAY_LOOPDEV=$(losetup -f --show ${readonly_overlay:+-r} "$mntDir$ovlpath")
            over=$OVERLAY_LOOPDEV
            umount -l "$mntDir" || :
            ovl_fstype="$(blkid --probe --match-tag TYPE --output value --usages filesystem "$OVERLAY_LOOPDEV")"
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
                    p_pt=$OVERLAY_LOOPDEV
                    # This leads to an overmount of $mntDir in /sbin/do-overlay
                    ovlpath=/overlayfs
                    ovl_dir=''
                    [ "$OverlayFS" ] || ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=${OverlayFS:=LiveOS_rootfs}"
                    setup=setup
                    ;;
            esac
        elif [ -d "$mntDir$ovlpath" ] && [ -d "$mntDir$ovlpath"/../ovlwork ]; then
            ## OverlayFS on xattr-enabled filesystem.
            [ "$OverlayFS" ] || ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=${OverlayFS:=LiveOS_rootfs}"
            setup=setup
        fi
    fi

    if [ ! "$setup" ] || [ "$readonly_overlay" ]; then
        if [ "$setup" ]; then
            info "Using a temporary overlay."
        elif [ "$p_pt" ] && [ "$ovlpath" ]; then
            prompt_message \
                '   Unable to find a persistent overlay; using a temporary one.' \
                '  All root filesystem changes will be lost on shutdown.' \
                '  Press [Enter] to continue.'
        fi
        [ "$OverlayFS" ] || {
            dd if=/dev/null of=/overlay bs=1024 count=1 seek=$((overlay_size * 1024)) 2> /dev/null
            if [ "$setup" ] && [ "$readonly_overlay" ]; then
                RO_OVERLAY_LOOPDEV=$(losetup -f --show /overlay)
                over=$RO_OVERLAY_LOOPDEV
            else
                OVERLAY_LOOPDEV=$(losetup -f --show /overlay)
                over=$OVERLAY_LOOPDEV
            fi
        }
    fi

    # set up the snapshot
    [ "$OverlayFS" ] || {
        if [ "$readonly_overlay" ] && [ "$OVERLAY_LOOPDEV" ]; then
            echo 0 "$sz" snapshot "$BASE_DEV" "$OVERLAY_LOOPDEV" P 8 | dmsetup create --readonly live-ro
            base=/dev/mapper/live-ro
        else
            base=$BASE_DEV
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

            THIN_META_LOOPDEV=$(losetup --show -f /run/initramfs/thin-overlay/meta)
            THIN_DATA_LOOPDEV=$(losetup --show -f /run/initramfs/thin-overlay/data)

            echo 0 $thin_data_sz thin-pool "$THIN_META_LOOPDEV" "$THIN_DATA_LOOPDEV" 1024 1024 | dmsetup create live-overlay-pool
            dmsetup message /dev/mapper/live-overlay-pool 0 "create_thin 0"

            # Create a snapshot of the base image
            echo 0 "$thin_data_sz" thin /dev/mapper/live-overlay-pool 0 "$base" | dmsetup create live-rw
        else
            echo 0 "$sz" snapshot "$base" "$over" PO 8 | dmsetup create live-rw
        fi
        # Create a device for the ro base of dm overlaid file systems.
        echo 0 "$sz" linear "$BASE_DEV" 0 | dmsetup create --readonly live-base
    }

    ln -s "$BASE_DEV" /dev/live-base
}
# end do_live_overlay()

# we might have an embedded fs image on SquashFS or EROFS (compressed live)
#   Source may be a mounted .iso image, an installed LiveUSB, or a link to an image partition.
for FSIMG in "$roroot_image" rorootfs.img rootfs.img ext3fs.img; do
    FSIMG=/run/initramfs/live/"$srcdir/$FSIMG"
    [ -e "$FSIMG" ] && break
done
if [ -e "$FSIMG" ]; then
    fsType="$(det_fs "$FSIMG")"
    case "$fsType" in
        erofs | squashfs) ro=ro ;;
        auto) Die "Could not determine filesystem type for $FSIMG." ;;
    esac
    [ "$live_ram" ] && src="$FSIMG" dst=/run/initramfs/"${ro:+ro}"rootfs.img var=FSIMG dd_copy
    # We have a link to a block device or setup a loop device for the image file.
    [ -b "$FSIMG" ] || FSIMG=$(losetup -r -f --show "$FSIMG")
    [ "$ro" ] && {
        ln -sf "$FSIMG" /run/initramfs/rorootfs
        # Mount the base root filesystem read-only.
        fstype="$fsType" srcPartition="$FSIMG" mountPoint=/run/rootfsbase \
            srcflags=ro mount_partition
    }
    # Check if the file system is the root image or contains an embedded image.
    if [ -d /run/rootfsbase/usr ] || [ -d /run/rootfsbase/ostree ]; then
        # If needed, adjust OverlayFS,
        #  or Die if OverlayFS is required but unavailable.
        if [ -d /sys/module/overlay ]; then
            [ "$OverlayFS" ] || {
                OverlayFS=LiveOS_rootfs
                ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=LiveOS_rootfs"
            }
        else
            Die 'OverlayFS is required but unavailable.'
            exit 1
        fi

    elif [ -d /run/rootfsbase/LiveOS ]; then
        for FSIMG in rootfs.img ext3fs.img; do
            FSIMG=/run/rootfsbase/LiveOS/"$FSIMG"
            [ -f "$FSIMG" ] && break
        done
        rm -- /run/initramfs/rorootfs
        [ -f "$FSIMG" ] || {
            Die "Failed to find an enbedded root filesystem image in the /LiveOS/ directory."
            exit 1
        }
        FSIMG=$(losetup -r -f --show "$FSIMG")
        fsType="$(det_fs "$FSIMG")"
        umount /run/rootfsbase
    fi
else
    Die "Failed to find a root filesystem in /run/initramfs/live/$srcdir/."
    exit 1
fi

case "$cfg" in
    ropt)
        install_Image
        ln -s "$FSIMG" /run/initramfs/rorootfs
        srcPartition="$FSIMG" mountPoint=/run/rootfsbase srcflags=ro mount_partition
        ;;
esac

if [ "$FSIMG" ]; then
    if [ "$writable_fsimg" ]; then
        # mount the provided filesystem read/write
        echo "Unpacking live filesystem (may take some time)" > /dev/kmsg
        mkdir -m 0755 -p /run/initramfs/fsimg/
        if [ "$ro" ]; then
            cp -v "$FSIMG" /run/initramfs/fsimg/rootfs.img
        else
            unpack_archive "$FSIMG" /run/initramfs/fsimg/
        fi
        FSIMG=/run/initramfs/fsimg/rootfs.img
    fi
    # For writable DM images...
    if [ ! "$ro" ] && [ "$live_ram" ] && [ ! "$OverlayFS" ] \
        || [ "$writable_fsimg" ] \
        || ! case "$rd_overlay" in none | None | NONE) false ;; esac then
        readonly_base=1
        if [ ! "$readonly_overlay" ]; then
            unset readonly_base
            setup=rw
        else
            setup=setup
        fi
    fi
    BASE_DEV="$FSIMG"
    [ "$OverlayFS" ] || {
        sz=$(($(blkid --probe --match-tag FSSIZE --output value --usages filesystem "$BASE_DEV") / 512))
    }
    if [ "$setup" = rw ]; then
        echo 0 "$sz" linear "$BASE_DEV" 0 | dmsetup create live-rw
    else
        # Prepare for mounting the overlay.
        do_live_overlay
    fi
fi

case "$cfg" in
    ropt)
        cfg=ropt_2
        install_Image
        ;;
esac

if [ "$OverlayFS" ]; then
    [ -h /run/initramfs/rorootfs ] || {
        if [ "$FSIMG" ]; then
            ln -sf "$FSIMG" /run/initramfs/rorootfs
            fstype="$fsType" srcPartition="$FSIMG" mountPoint=/run/rootfsbase \
                srcflags=ro mount_partition
        else
            [ -d /sys/module/overlay ] || Die 'OverlayFS is required but unavailable.'
            # Support legacy case of OverlayFS over traditional root block device.
            ln -sf /run/initramfs/live /run/rootfsbase
            [ "$OverlayFS" = 1 ] && OverlayFS=os_rootfs
        fi
    }
    # From rd.overlay=1 case
    [ "$OverlayFS" = 1 ] && {
        OverlayFS="$rd_overlay"
        etc_kernel_cmdline="$etc_kernel_cmdline rd.overlay=$rd_overlay"
    }
    ovl_dir="$ovl_dir"
    # Add an OverlayFS for persistent writes.
    [ "$p_pt" ] && do_overlayfs
else
    [ "${DRACUT_SYSTEMD-}" ] || printf \
        'mount %s /dev/mapper/live-rw %s\n' "${rflags:+-o $rflags}" "$NEWROOT" \
        > "$hookdir"/mount/01-$$-live.sh
    need_shutdown
fi

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
