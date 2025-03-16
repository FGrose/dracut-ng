#!/bin/sh
# fedora-lib.sh: utilities for Fedora® image configuration, especially
#   GRUB boot configuration.

# Wrapper for additional mount flags or filesystem options for fsType $1,
#   appended to any from the command line.
# Set default mkfs extra attributes, if none from the command line.
# $1 - fsType
# $2 - flag_variable (p_ptFlags or rflags)
set_FS_opts_w() {
    command -v set_FS_options > /dev/null || . /lib/fs-lib.sh
    local rd_flags
    case "$2" in
        p_ptFlags)
            rd_flags=$(getarg rd.ovl.flags)
            rd_flags=lazytime"${rd_flags:+,"$rd_flags"}"
            ;;
        rflags)
            rd_flags=$(getarg rootflags=) ;;
    esac
    case "$1" in
        btrfs)
            rd_flags="${rd_flags:+"${rd_flags}"}${subvol:+,subvol="$subvol"}",compress=zstd:3
            ;;
        f2fs)
            strstr "${extra_attrs:=extra_attr,inode_checksum,sb_checksum,compression}" compression \
                && rd_flags="${rd_flags:+"${rd_flags}",}"'compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge'
            ;;
        ext[432])
            # Set default fsckoptions overideable by <mountpoint>/fsckoptions.
            fsckoptions='-E discard'
            ;;
    esac
    # Execute setting through function in fs-lib.sh
    set_FS_options "$2" "$rd_flags"
}

update_BootConfig() {
    local _ovl_dir root rootcfg livedev ovl_spec ovl _TITLE GRUB_cfg cfg UUID ovl_uuid sedcmd label
    cfg=$(readlink /run/initramfs/cfg)
    cfg="${cfg%%[:,+]*}"
    if [ "$mntDir" ]; then
        # OverlayFS present.
        OverlayFS=rd\.overlay=LiveOS_rootfs
        root=/run/rootfsbase
        livedev=$mntDir
    else
        root=$NEWROOT
        livedev=$root
    fi

    # shellcheck disable=SC2046
    set -- $(findmnt -nro SOURCE,UUID "$livedev")
    livedev=$1
    UUID=$2

    # Transfer boot directory files to ESP.
    mount -n -m --bind /run/initramfs/ESP "$root"/mnt
    LC_ALL=C chroot "$root" find /boot/. -maxdepth 1 \! -type d -execdir cp --dereference --preserve=all "{}" "/mnt/$ovl_dir/$BOOTDIR/{}" \;
    umount "$root"/mnt
    sync -f /run/initramfs/ESP/"$ovl_dir"

    # Backup previous configuration.
    cp -a "${GRUB_cfg:=/run/initramfs/ESP/EFI/BOOT/grub.cfg}" "$GRUB_cfg".prev

    # Remove unwanted menuentries in Fedora .iso configuration
    sedcmd="/^\s*menuentry\s+('|\")Test this media/,/^}$/ d"

    # Keep only the first 2 menu/submenu bracketed entries.
    #   (Uses exchange and '.' as a flag in the hold buffer to count matches;
    #    q to ignore pattern buffer and quit.)
    sedcmd="$sedcmd
/^}$/{x;/./{x;q};s/.*/&./;x}"
    sed -i -r "$sedcmd" "$GRUB_cfg"

    # Escape special characters for sed regex and replacement strings.
    # string - $@
    escape() {
        sed 's/[]\/;$*.^?+|{}&[]/\\&/g' << E
$@
E
    }

    _ovl_dir="$(escape "$ovl_dir")"

    # Extract image title.
    _TITLE="$(
        sed -n -r "
        0,/^menuentry/ s;.*('|\")Start\s+(w/persistence|a transient|)( \S+\s+~|)(.*)('|\") .*;\4; p" "$GRUB_cfg"
    )"
    _TITLE="$(escape "$_TITLE")"
    ROOTFLAGS=$(getarg rootflags) && {
        # Remove duplicated root flags & appended ro.
        ROOTFLAGS=$(
            sed -r ':a;s/(,(\S+),.*)\2,/\1/;ta' << E
,${ROOTFLAGS%,ro},
E
        )
        ROOTFLAGS=${ROOTFLAGS#,}
        ROOTFLAGS=${ROOTFLAGS%,}
    }
    _BOOTDIR="$(escape "${BOOTDIR}")"

    # Reset template menuentries to base state.
    # Distinguish the new grub menuentry with '$_ovl_dir ~'.
    [ "$ovl_dir" = LiveOS ] && unset -v _ovl_dir
    sed -i -r "1 s/^\s*set\s+default=.*/set default=0/
s/^\s*set\s+timeout=.*/set timeout=60/
/^\s*menuentry/ {
s/\S+\s+~$_TITLE/$_TITLE/
s;(^menuentry\s+).*$_TITLE.*('|\");\1\2Start w/persistence ${_ovl_dir:+$_ovl_dir\ ~}$_TITLE\2;
}
s/^search\s+.*/### BEGIN/
/^\s*(search|for|initrds|done)\>/ d
/^\s*insmod\s+(ext2|fat|xfs|f2fs|btrfs)\>/ d
/^\s*menu_item/ d
s/(^submenu ('|\")Troubleshoot).* \{$/\1 -->\2 \{/
/^\s+linux|initrd/ {
s;(linux|initrd)(\S*)\s+\S+(linux|vmlinuz.?|initrd|initrd.?\.img);\1\2 /$_BOOTDIR/\3;
s/\s+initrd=\S+//
s/\s+rootflags=\S*//
s/\<rd\.live\.\S+\s*//g
s/\s+(ro|rw)(\s+|$)/ /
s;iso-scan/filename=\S+ ; ;
s/root=live:\S+ /root=live:CDLABEL=placeholder /
    /\s+(\\$\\{basicgfx\\}|nomodeset)($|\s+)/ {
s/\s+(\\$\\{basicgfx\\}|nomodeset)($|\s+)/ \1 rd\.debug\2/
s/\s+(quiet|rhgb|splash)\s+(quiet|rhgb|splash)\s+/ /
    }
}" "$GRUB_cfg"

    ovl="$(escape "${ovlfsdir##*/}")"
    ovl_spec="\/${_ovl_dir:-LiveOS}\/$ovl"

    # Update menu entries for the new installation.
    rootcfg=UUID=$UUID
    ovl_spec="${UUID}${ovl_spec:+:$ovl_spec}"
    ovl_uuid=$UUID

    case "$cfg" in
        ovl) rootcfg=UUID=$(readlink /run/initramfs/live_uuid) ;;
        iso | ciso)
            label=$(realpath /run/initramfs/isofile)
            label="${label##*/}"
            rootcfg="/dev/loop0p1 iso-scan/filename=UUID=$(findmnt -nro UUID /run/initramfs/isoscandev):isos/${label}"
            ;;           
        ropt | '')
            # SquashFS lacks UUID, use the disk partition's PARTUUID.
            rootcfg=PARTUUID=$(readlink /run/initramfs/live_partuuid)
            root_arg=$rootcfg
            ;;
    esac
    cfgargs="${ROOTFLAGS:+ rootflags=$ROOTFLAGS}"
    cfgargs="$(escape "$cfgargs")"
    rootcfg="$rootcfg${_live_dir:+ rd.live.dir=$_live_dir}"
    rootcfg="$(escape "$rootcfg")"
    [ "$IMG" = initrd.img ] && IMG=initrd*.img

    # shellcheck disable=SC2016
    sed -i -r "/^### BEGIN/ i\
insmod fat\\
search --no-floppy --efidisk-only --set esp -u ${esp_uuid}
               /^\s*linux/ {
               i\
\    for f in (\$esp)/${_ovl_dir:=LiveOS}/$_BOOTDIR/$IMG*; do\\
\        initrds=\"\$initrds \$f\"\\
\    done
               s/root=live:CDLABEL=\S+/root=live:$rootcfg rw${ovl_spec:+ rd\.overlay=UUID=$ovl_spec,LiveOS_rootfs} $cfgargs/
               }
               /^\s+linux|initrd/ {
               s;(\s*(linux|initrd)\S*\s+).*(/$_BOOTDIR);\1(\$esp)/$_ovl_dir\3;
               }
               /^### BEGIN/,$ {
               s/(^\s*initrd\S*\s+)\S+/\1\$initrds/
               s/(^submenu ('|\"))Troubleshoot.* \\{$/\1   Alternative boots \^ for the above image \^ -->\2 \\{/
               }
               /^\s*submenu\s+/ a\
\	${root_arg:+root_arg=$root_arg}\\
\	menu_item 'Start a pristine, transient $_TITLE' '$_BOOTDIR' '' (\$esp)/'$_ovl_dir' '$rootcfg' '$cfgargs'\\
\	menu_item 'Start the saved -$_ovl_dir- image readonly via a RAM overlay' '$_BOOTDIR' '' (\$esp)/'$_ovl_dir' '$rootcfg' 'rd.ovl.flags=ro rd.overlay.readonly rd.overlay=UUID=$UUID:/$_ovl_dir/$ovl $cfgargs'\\
\	menu_item 'Make a new, persistent overlay directory for the base image' '$_BOOTDIR' '' (\$esp)/'$_ovl_dir' '${rootcfg% rd\.ovl\.dir*}' 'rd.ovl.dir=PROMPT rd.overlay=UUID=$UUID,new_pt_for$_ovl_dir $cfgargs'\\
\	menu_item 'Format a new, persistence partition for the -$_ovl_dir- base image' '$_BOOTDIR' '' (\$esp)/'$_ovl_dir' '${rootcfg% rd\.ovl\.dir*}' 'rd.ovl.dir=PROMPT rd.overlay=new_pt_for$_ovl_dir,PROMPTSZ,PROMPTFS $cfgargs'\\
\	menu_item 'Reset any persistent overlay & start the -$_ovl_dir- base image' '$_BOOTDIR' '' (\$esp)/'$_ovl_dir' '$rootcfg' 'rd.overlay.reset rd.overlay=UUID=$UUID:/$_ovl_dir/$ovl $cfgargs'
               /^\s*menuentry\s+/ {
               s;(Start \S+).*(in basic graphics mode).*('|\");Start the -$_ovl_dir- image \2 w/debug log\3;
               }
               /^\s*$/ d
" "$GRUB_cfg"

    if [ ! -f "$GRUB_cfg".multi ]; then
        # Retrieve ISOSCAN block, if present on first configuration.
        sed -n -r '/^### ISOSCAN/, /^### end_ISOSCAN/ w /tmp/isoscan' "$GRUB_cfg".prev
        [ -s /tmp/isoscan ] && cat /tmp/isoscan >> "$GRUB_cfg"
    else
        # Case of previous installation, insert ... & null lines after stanzas.

        sed -i -r '1 i\
...
        /^### BEGIN/,$ {
        /^\}$/ a

}' "$GRUB_cfg".multi

        # Collect null-separated stanzas into single lines exchanged to pattern space.
        # Remove each menuentry stanza with conflicting bootpath and root ID:
        rootcfg=${rootcfg%% *}
        sed -i -r "/./ {H;\$!d};x
        /^### BEGIN/,/^### ISOSCAN/ {
        s;.*\/$_ovl_dir\/.* root=live:$rootcfg .*;;}" "$GRUB_cfg".multi

        # Append other pre-existing menus.
        cat "$GRUB_cfg".multi >> "$GRUB_cfg"

        # Clear header & null lines that came from $GRUB_cfg.multi.
        sed -i -r '/^\.\.\.$/,/^\s*menuentry\s+/ {
               /^\s*menuentry\s+/ ! d}
               /^### BEGIN/,$ {
               /^\s*$/ d}' "$GRUB_cfg"
        rm "$GRUB_cfg".multi
    fi

    # shellcheck disable=SC2046
    set -- $(lsblk -dnpo NAME,VENDOR,MODEL,REV,SERIAL,SIZE /run/initramfs/diskdev)
    target="$(escape "$@")"
    SERIAL="$(escape "$(eval printf '%s' $\{$(($# - 1))\})")"
    # Update ISOSCAN menu_item for current persistence partition & disc.
    sed -i -r "s/(\s+rd\.(overlay|live\.image)=UUID=)[-a-fA-F0-9]+( |,\S+ )/\1${ovl_uuid}\3/
        s;(serial=).*(\/serial\/);\1$SERIAL\2;
        s/(TARGET: ').*'/\1$target'/" "$GRUB_cfg"

    [ -b /run/initramfs/p_pt ] && {
        # Condition of newly created persistence partition.
        sed -i -r "/^### ISOSCAN/, /^### end_ISOSCAN/ !{
s/rd\.overlay=\S*/rd\.overlay=UUID=$UUID ${ROOTFLAGS:+rootflags=$ROOTFLAGS }/
s;(new_pt_for.*|serial=.*/)\S*;\1 rd\.overlay=UUID=$UUID ${ROOTFLAGS:+rootflags=$ROOTFLAGS };
}" "$GRUB_cfg"
    }
    [ -e "$GRUB_cfg".set ] || set_flag
}

set_flag() {
    # Set a flag file to record completion of this function.
    : > "$GRUB_cfg".set
}
