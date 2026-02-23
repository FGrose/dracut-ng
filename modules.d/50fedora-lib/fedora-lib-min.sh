#!/bin/sh
# (fedora)distribution-lib-min.sh:
# core functions for minimal sourcing, such as for early boot generators.

# Additional mount flags prepended to any from the command line for fsType.
# Set default mkfs extra attributes, if not present on the command line for
#   the root or a persistent overlay bearing partition.
# $1 - fsType
# $2 - flag_var (ptFlags or rflags)
set_FS_options() {
    local - fsType="$1" flag_var="$2" param flags
    set -x
    case "$flag_var" in
        ptFlags) param=rd.ovl.flags ;;
        rflags) param=rootflags ;;
    esac
    flags=$(getarg "$param")
    case "$fsType" in
        btrfs)
            [ "$subvol" ] && flags="subvol=$subvol,${flags:+$flags}"
            flags=compress=zstd:1,"${flags:+$flags}"
            ;;
        f2fs)
            case "${extra_attrs:=extra_attr,inode_checksum,sb_checksum,compression}" in
                *compression*) flags=compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,"${flags:+$flags}" ;;
            esac
            ;;
        ext[432])
            fsckoptions='-E discard'
            ;;
    esac
    if [ "$flags" ] && [ "$param" ]; then
        mkdir -p /etc/kernel
        printf ' %s=%s' "$param" "$flags" >> /etc/kernel/cmdline
    fi
    read -r "$flag_var" << EOF
$flags
EOF
    export "$flag_var"
}
