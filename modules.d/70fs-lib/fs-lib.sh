#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

fsck_ask_reboot() {
    info "note - fsck suggests reboot, if you"
    info "leave shell, booting will continue normally"
    emergency_shell -n "(reboot ?)"
}

fsck_ask_err() {
    warn "*** An error occurred during the file system check."
    warn "*** Dropping you to a shell; the system will try"
    warn "*** to mount the filesystem(s), when you leave the shell."
    emergency_shell -n "(Repair filesystem)"
}

# inherits: _ret _drv _out
fsck_tail() {
    [ "$_ret" -gt 0 ] && warn "$_drv returned with $_ret"
    if [ "$_ret" -ge 4 ]; then
        [ -n "$_out" ] && echo "$_out" | vwarn
        fsck_ask_err
    else
        [ -n "$_out" ] && echo "$_out" | vinfo
        [ "$_ret" -ge 2 ] && fsck_ask_reboot
    fi
}

# note: this function sets _drv of the caller
fsck_able() {
    case "$1" in
        xfs)
            # {
            #     type xfs_db &&
            #     type xfs_repair &&
            #     type xfs_check &&
            #     type mount &&
            #     type umount
            # } >/dev/null 2>&1 &&
            # _drv="_drv=none fsck_drv_xfs" &&
            # return 0
            return 1
            ;;
        ext?)
            type e2fsck > /dev/null 2>&1 \
                && _drv="fsck_drv_com e2fsck" \
                && return 0
            ;;
        f2fs)
            type fsck.f2fs > /dev/null 2>&1 \
                && _drv="fsck_drv_com fsck.f2fs" \
                && return 0
            ;;
        jfs)
            type jfs_fsck > /dev/null 2>&1 \
                && _drv="fsck_drv_com jfs_fsck" \
                && return 0
            ;;
        btrfs)
            # type btrfsck >/dev/null 2>&1 &&
            # _drv="_drv=none fsck_drv_btrfs" &&
            # return 0
            return 1
            ;;
        nfs*)
            # nfs can be a nop, returning success
            _drv=":" \
                && return 0
            ;;
        *)
            type fsck > /dev/null 2>&1 \
                && _drv="fsck_drv_std fsck" \
                && return 0
            ;;
    esac

    return 1
}

# note: all drivers inherit: _drv _fop _dev

fsck_drv_xfs() {
    # xfs fsck is not necessary... Either it mounts or not
    return 0
}

fsck_drv_btrfs() {
    # btrfs fsck is not necessary... Either it mounts or not
    return 0
}

# common code for checkers that follow usual subset of options and return codes
fsck_drv_com() {
    local _drv="$1"
    local _ret
    local _out

    if ! strglobin "$_fop" "-[ynap]"; then
        _fop="-a${_fop:+ "$_fop"}"
    fi

    info "issuing $_drv $_fop $_dev"
    # we enforce non-interactive run, so $() is fine
    # shellcheck disable=SC2086
    _out=$($_drv $_fop "$_dev")
    _ret=$?
    fsck_tail

    return $_ret
}

# code for generic fsck, if the filesystem checked is "unknown" to us
fsck_drv_std() {
    local _ret
    local _out
    unset _out

    info "issuing fsck $_fop $_dev"
    # note, we don't enforce -a here, thus fsck is being run (in theory)
    # interactively; otherwise some tool might complain about lack of terminal
    # (and using -a might not be safe)
    # shellcheck disable=SC2086
    fsck $_fop "$_dev" > /dev/console 2>&1
    _ret=$?
    fsck_tail

    return $_ret
}

# checks single filesystem, relying on specific "driver"; we don't rely on
# automatic checking based on fstab, so empty one is passed;
# takes 4 arguments - device, filesystem, filesystem options, additional fsck options;
# first 2 arguments are mandatory (fs may be auto or "")
# returns 255 if filesystem wasn't checked at all (e.g. due to lack of
# necessary tools or insufficient options)
fsck_single() {
    local FSTAB_FILE=/etc/fstab.empty
    local _dev="$1"
    local _fs="${2:-auto}"
    local _fop="$4"
    local _drv

    [ $# -lt 2 ] && return 255
    _dev=$(readlink -f "$(label_uuid_to_dev "$_dev")")
    [ -e "$_dev" ] || return 255
    _fs=$(det_fs "$_dev" "$_fs")
    fsck_able "$_fs" || return 255

    info "Checking $_fs: $_dev"
    export FSTAB_FILE
    eval "$_drv"
    return $?
}

# takes list of filesystems to check in parallel; we don't rely on automatic
# checking based on fstab, so empty one is passed
fsck_batch() {
    local FSTAB_FILE=/etc/fstab.empty
    local _drv=fsck
    local _dev
    local _ret
    local _out

    [ $# -eq 0 ] || ! command -v fsck > /dev/null && return 255

    info "Checking filesystems (fsck -M -T -a):"
    for _dev in "$@"; do
        info "    $_dev"
    done

    export FSTAB_FILE
    _out="$(fsck -M -T "$@" -- -a)"
    _ret=$?

    fsck_tail

    return $_ret
}

# verify supplied filesystem type:
# if user provided the fs and we couldn't find it, assume user is right
# if we found the fs, assume we're right
# Works for block devices or image files.
det_fs() {
    local _dev="$1"
    local _orig="${2:-auto}"
    local _fs

    _fs=$(blkid "$_dev")
    _fs="${_fs#*TYPE=\"}"
    _fs="${_fs%%\"*}"
    _fs=${_fs:-auto}

    if [ "$_fs" = "auto" ]; then
        _fs="$_orig"
    fi
    echo "$_fs"
}

write_fs_tab() {
    local _o
    local _rw
    local _root
    local _rootfstype
    local _rootflags
    local _fspassno

    _fspassno="0"
    _root="$1"
    _rootfstype="$2"
    _rootflags="$3"
    [ -z "$_rootfstype" ] && _rootfstype=$(getarg rootfstype=)
    [ -z "$_rootflags" ] && _rootflags=$(getarg rootflags=)

    [ -z "$_rootfstype" ] && _rootfstype="auto"

    if [ -z "$_rootflags" ]; then
        _rootflags="ro,x-initrd.mount"
    else
        _rootflags="ro,$_rootflags,x-initrd.mount"
    fi

    _rw=0

    CMDLINE=$(getcmdline)
    for _o in $CMDLINE; do
        case $_o in
            rw)
                _rw=1
                ;;
            ro)
                _rw=0
                ;;
        esac
    done
    if [ "$_rw" = "1" ]; then
        _rootflags="$_rootflags,rw"
        if ! getargbool 0 rd.skipfsck; then
            _fspassno="1"
        fi
    fi

    if grep -q "$_root /sysroot" /etc/fstab; then
        echo "$_root /sysroot $_rootfstype $_rootflags $_fspassno 0" >> /etc/fstab
    else
        return
    fi

    if type systemctl > /dev/null 2> /dev/null; then
        systemctl daemon-reload
        systemctl --no-block start initrd-root-fs.target
    fi
}

mkfs_config() {
    local fsType=$1
    local lbl=$2
    local sz=$3    # filesystem size in bytes
    local attrs=$4 # comma-separated string of options
    local ops=''
    case "$fsType" in
        btrfs)
            # mkfs.btrfs maximum label length is 255 characters.
            lbl=$(str_truncate "$lbl" 255)
            ops="${attrs:+$attrs }-f -L $lbl"
            # Recommended for out of space problems on filesystems under 16 GiB.
            # https://btrfs.wiki.kernel.org/index.php/FAQ#if_your_device_is_small
            [ "$sz" -lt $((1 << 34)) ] && ops="${ops} --mixed"
            ;;
        ext[432])
            case "$fsType" in
                ext[43]) ops='-j' ;;
            esac
            # mkfs.ext[432] maximum label length is 16 bytes.
            lbl=$(str_truncate "$lbl" 16)
            ops="${attrs:+$attrs }${ops:+"${ops} "}-F -L $lbl"
            # Recommended for filesystems under 512 MiB.
            # https://manned.org/mkfs.ext4.8
            [ "$sz" -lt $((1 << 29)) ] && ops="${ops} -T small"
            ;;
        fat)
            # mkfs.fat silently truncates label to 11 bytes.
            lbl=$(str_truncate "$lbl" 11)
            ops="${attrs:+$attrs }-c${VERBOSE:+v}n $lbl"
            ;;
        f2fs)
            # mkfs.f2fs maximum label length is 512 unicode characters.
            lbl=$(str_truncate "$lbl" 512)
            ops="-f -l $lbl ${attrs:+-O $attrs}"
            ;;
        xfs)
            # mkfs.xfs maximum label length is 12 characters.
            lbl=$(str_truncate "$lbl" 12)
            ops="${attrs:+$attrs }-f -L $lbl"
            ;;
    esac
    [ "$fsType" = fat ] || ops="${QUIET:+-q }$ops"
    mkfs_cmd=mkfs."$fsType $ops"
}

create_Filesystem() {
    local fsType=$1
    local dev=$2
    local out=/dev/kmsg
    [ "$QUIET" ] && out=/dev/null

    printf 'Making %s filesystem on %s.
' $fsType "$dev" > /dev/kmsg

    load_fstype "$fsType"
    # shellcheck disable=SC2086
    LC_ALL=C flock "$dev" $mkfs_cmd "$dev" > "$out" 2>&1 \
        || die "Failed to make filesystem with '$mkfs_cmd $dev'."
    # Update udev_db for fs info changes.
    udevadm trigger --name-match "$dev" --action change --settle > /dev/kmsg 2>&1
}

# Additional mount flags appended to any from the command line.
# $1 - flag_variable (p_ptFlags or rflags)
# $2 - flagstring from set_FS_opts_w() in <distribution>-lib.sh
set_FS_options() {
    local rd_flags rd_arg
    if ! [ "$2" ]; then
        case "$1" in
            p_ptFlags) rd_flags=$(getarg rd.ovl.flags) ;;
            rflags) rd_flags=$(getarg rootflags=) ;;
        esac
    else
        case "$1" in
            p_ptFlags) rd_arg=rd.ovl.flags ;;
            rflags) rd_arg=rootflags ;;
        esac
        # Record additional mount flags for other users.
        mkdir -p /etc/kernel
        printf '%s' " $rd_arg=$2" >> /etc/kernel/cmdline
    fi
    eval "$1=${2:-$rd_flags}"
}

# Wrapper function to set_FS_options for additional mount flags for fsType $1
# Set default mkfs extra attributes, if none from the command line.
# $1 - fsType
# $2 - flag_variable (p_ptFlags or rflags)
### FIXME to be moved to <distribution>-lib.sh
set_FS_opts_w() {
    local rd_flags
    case "$2" in
        p_ptFlags)
            rd_flags=$(getarg rd.ovl.flags)
            [ "$rd_flags" ] || rd_flags=lazytime
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
