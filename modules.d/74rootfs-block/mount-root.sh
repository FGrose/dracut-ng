#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v det_fs > /dev/null || . /lib/fs-lib.sh

# Call with preset arguments like:
#  [fstype=<fstype>] srcPartition=<srcPartition> mountPoint=<mountPoint> \
#      [srcflags=<srcflags>] [fsckoptions=<fsckoptions>] [override=override] \
#      . /path/to/this/script
# Use arg override=override to invoke an alternative mount.
mount_source() {
    local - srcPartition mountPoint srcflags _srcflags_ro fsckoptions
    set +x
    # sanity - determine/fix fstype
    srcfsType=$(det_fs "$srcPartition" "$fstype")

    journaldev=$(getarg "root.journaldev=")
    if [ -n "$journaldev" ]; then
        case "$srcfsType" in
            xfs)
                srcflags="${srcflags:+${srcflags},}logdev=$journaldev"
                ;;
            *) ;;
        esac
    fi

    _srcflags_ro="$srcflags,ro"
    _srcflags_ro="${_srcflags_ro##,}"

    while ! mount -t "${srcfsType}" -o "$_srcflags_ro" "$srcPartition" "$mountPoint"; do
        warn "Failed to mount -t ${srcfsType} -o $_srcflags_ro $srcPartition $mountPoint"
        fsck_ask_err
    done

    fsckoptions=${fsckoptions-}
    [ -f "$mountPoint"/etc/sysconfig/readonly-root ] \
        && . "$mountPoint"/etc/sysconfig/readonly-root

    [ -f "$mountPoint"/fastboot ] || getargbool 0 fastboot && fastboot=yes

    if ! getargbool 0 rd.skipfsck; then
        [ -f "$mountPoint/fsckoptions" ] \
            && read -r fsckoptions < "$mountPoint/fsckoptions"


        if [ -f "$mountPoint"/forcefsck ] || getargbool 0 forcefsck; then
            fsckoptions="-f $fsckoptions"
        elif [ -f "$mountPoint"/.autofsck ]; then
            # shellcheck disable=SC1090
            [ -f "$mountPoint"/etc/sysconfig/autofsck ] \
                && . "$mountPoint"/etc/sysconfig/autofsck

            [ "$AUTOFSCK_DEF_CHECK" = "yes" ] && AUTOFSCK_OPT="$AUTOFSCK_OPT -f"

            if [ "$AUTOFSCK_SINGLEUSER" ]; then
                warn "*** Warning -- the system did not shut down cleanly. "
                warn "*** Dropping you to a shell; the system will continue"
                warn "*** when you leave the shell."
                emergency_shell
            fi
            fsckoptions="$AUTOFSCK_OPT $fsckoptions"
        fi
    fi

    local srcopts=
    local srcfsck=
    if getargbool 1 rd.fstab \
        && ! getarg rootflags > /dev/null \
        && [ -f "$mountPoint/etc/fstab" ] \
        && ! [ -L "$mountPoint/etc/fstab" ]; then
        # if $mountPoint/etc/fstab contains special mount options for
        # the root filesystem,
        # remount it with the proper options
        srcopts="defaults"
        while read -r dev mp fs opts _ fsck || [ -n "$dev" ]; do
            # skip comments
            [ "${dev%%#*}" != "$dev" ] && continue

            if [ "$mp" = "/" ]; then
                # sanity - determine/fix fstype
                srcfsType=$(det_fs "$srcPartition" "$fs")
                srcopts=$opts
                srcfsck=$fsck
                break
            fi
        done < "$mountPoint/etc/fstab"
    fi

    # we want srcflags (for root, rootflags - rflags) to take precedence
    #  so prepend srcopts tothem
    srcflags="${srcopts},${srcflags}"
    srcflags="${srcflags#,}"
    srcflags="${srcflags%,}"

    # backslashes are treated as escape character in fstab
    # esc_root=$(echo $srcPartition | sed 's,\\,\\\\,g')
    # printf '%s %s %s %s 1 1 \n' "$esc_root" "$mountPoint" "$srcfsType" "$srcflags" >/etc/fstab

    if ! getargbool 0 ro && fsck_able "$srcfsType" \
        && [ "$srcfsck" != "0" ] && [ -z "$fastboot" ] \
        && ! strstr "${srcflags}" _netdev \
        && ! getargbool 0 rd.skipfsck; then
        umount "$mountPoint"
        fsck_single "$srcPartition" "$srcfsType" "$srcflags" "$fsckoptions"
    fi

    echo "$srcPartition $mountPoint $srcfsType ${srcflags:-defaults} 0 ${srcfsck:-0}" >> /etc/fstab

    if ! ismounted "$mountPoint"; then
        info "Mounting $srcPartition${srcflags:+ with -o $srcflags}"
        mount "$mountPoint" 2>&1 | vinfo
    elif ! are_lists_eq , "$srcflags" "$_srcflags_ro" defaults; then
        info "Remounting $srcPartition${srcflags:+ with -o $srcflags}"
        mount -o remount "$mountPoint" 2>&1 | vinfo
    fi

    if ! getargbool 0 rd.skipfsck; then
        [ -f "$mountPoint"/forcefsck ] && rm -f -- "$mountPoint"/forcefsck 2> /dev/null
        [ -f "$mountPoint"/.autofsck ] && rm -f -- "$mountPoint"/.autofsck 2> /dev/null
    fi
}

if [ "$override" = override ]; then
    srcPartition="$srcPartition" mountPoint="$mountPoint" srcflags="$srcflags" fsckoptions="$fsckoptions" mount_source
elif [ "$root" ] && [ -z "${root%%block:*}" ]; then 
    srcPartition="${root#block:}" mountPoint="$NEWROOT" srcflags="$rflags" fsckoptions="$fsckoptions" mount_source
fi
