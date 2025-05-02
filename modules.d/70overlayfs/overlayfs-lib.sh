#!/bin/sh
# overlayfs-lib.sh: utilities for OverlayFS use

# Avoid re-triggering these rules.
rm -- /etc/udev/rules.d/99-overlayfs.rules 2> /dev/null && udevadm control --reload

# Set default mount flags for fsType $1, if none from the command line.
# Set default mkfs extra attributes if none from the command line.
set_FS_options() {
    p_ptfsType=$1
    case "$p_ptfsType" in
        btrfs)
            p_ptFlags='compress=zstd:3'
            ;;
        f2fs)
            strstr "${extra_attrs:=extra_attr,inode_checksum,sb_checksum,compression}" compression \
                && p_ptFlags='compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge'
            ;;
    esac
    local rd_ovl_flags
    rd_ovl_flags=$(getarg rd.ovl.flags)
    if [ "$rd_ovl_flags" ]; then
        p_ptFlags="$rd_ovl_flags"
    else
        p_ptFlags=${p_ptFlags:+${p_ptFlags},}lazytime
        # Record default mount flags for other users.
        mkdir -p /etc/kernel
        printf '%s' " rd.ovl.flags=$p_ptFlags" >> /etc/kernel/cmdline
    fi
}

mount_p_Partition() {
    # Repurpose rootfs-block/mount-root.sh for the persistence partition.
    . /sbin/mount-root
    [ -d "${mntDir:=/run/initramfs/LiveOS_persist}" ] || mkdir -p "$mntDir"
    fstype="${p_ptfsType:-auto}" srcPartition="$ovl_pt" mountPoint="$mntDir" srcflags="$p_ptFlags" mount_source
    if findmnt "$mntDir" > /dev/null 2>&1; then
        mkdir -p "$mntDir${ovl_dir:+/"$ovl_dir"}${OverlayFS:+/ovlwork}" "$mntDir$ovlpath"
    else
        prompt_message \
            '   Failed to mount the persistent overlay; using a temporary one.' \
            '  All new root filesystem changes will be lost on shutdown.' \
            '  Press [Enter] to continue.'
    fi
}

do_overlayfs() {
    if [ ! "$ovlpath" ] || [ "$ovlpath" = "auto" ]; then
        ovlpath="/${ovl_dir}/overlay-$label-$uuid"
    elif ! str_starts "$ovlpath" "/"; then
        ovlpath=/"${ovlpath}"
    fi

    if [ "$ovlpath" ]; then
        mkdir -m 0755 -p "${mntDir:=/run/initramfs/LiveOS_persist}"
        # shellcheck disable=SC2046
        set -- $(findmnt -d backward -fnro TARGET "$ovl_pt")
        if [ "$1" ]; then
            # We need $ovl_pt writable for overlay storage
            [ ! -w "$mntDir" ] && [ ! "$readonly_overlay" ] && mount -o remount,rw "$mntDir"
        else
            [ "$p_ptFlags" ] || set_FS_options "${p_ptfsType:=$(blkid --probe --match-tag TYPE --output value --usages filesystem "$ovl_pt")}"
            mount_p_Partition
        fi
        if [ "${mntDir##*/}" = os_persist ] && [ -d "$mntDir$ovlpath" ] && [ -d "$mntDir$ovlpath"/../ovlwork ]; then
            echo "Checking md5sum for $root_pt ... This may take several minutes. Please wait..." > /dev/kmsg
            md5sum_new=$(md5sum "$root_pt")
            md5sum_new=${md5sum_new%% *}
            read -r md5sum < "$mntDir$ovlpath"/.md5sum
            [ "$md5sum" = "$md5sum_new" ] || {
                info "Resetting the OverlayFS overlay directory."
                rm -r -- "$mntDir$ovlpath" 2> /dev/kmsg
                mkdir -p "$mntDir$ovlpath"
            }
            printf '%s' "$md5sum_new" > "$mntDir$ovlpath"/.md5sum
        fi
        # Establish links needed for the OverlayFS mount.
        ln -s "$mntDir$ovlpath" /run/overlayfs${readonly_overlay:+-r}
        [ "$readonly_overlay" ] || ln -s "$mntDir$ovlpath"/../ovlwork /run/ovlwork
        setup=OverlayFS_setup
    fi

    if [ "$readonly_overlay" ]; then
        if [ "$setup" ]; then
            info "Using a temporary overlay."
        elif [ "$ovl_pt" ] && [ "$ovlpath" ]; then
            prompt_message \
                '   Unable to find a persistent overlay; using a temporary one.' \
                '  All root filesystem changes will be lost on shutdown.' \
                '  Press [Enter] to continue.'
        fi
        if [ "${OverlayFS}$rd_overlayfs" ] && ! [ -h /run/overlayfs-r ]; then
            prompt_message \
                '   Failed to find a persistent overlay; using a temporary one.' \
                '  All root filesystem changes will be lost on shutdown.' \
                '  Press [Enter] to continue.'
            unset -v 'readonly_overlay'
            ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlayfs.readonly=0"
        fi
    fi
}
