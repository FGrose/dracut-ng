#!/bin/sh
# partition-lib-min.sh:
# core functions for minimal sourcing, such as for early boot generators.

plymouth --ping > /dev/null 2>&1 && {
    export PLYMOUTH=PLYMOUTH
    . /lib/plymouth-lib.sh
}

# Additional mount flags appended to any from the command line.
# $1 - flag_variable (p_ptFlags or rflags)
# $2 - flagstring from set_FS_opts_w() in <distribution>-lib.sh or stub version
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

# Stub wrapper for additional filesystem flags - generator version
# $1 - fsType (ignored) $2 - flag_variable (p_ptFlags or rflags)
set_FS_opts_w() {
    set_FS_options "$2" "$p_ptFlags"
}

# Call with IFS=, parse_cfgArgs $1="<cfg>,<comma-separated input string>"
#   $1 becomes $@
parse_cfgArgs() {
    local - missing_or_auto_case
    set -x
    # shellcheck disable=SC2068
    set -- $@
    IFS=' 	
'
    case "$1" in
        ovl | img)
            missing_or_auto_case() {
                p_ptfsType=${1:-${p_ptfsType:-ext4}}
                espStart=1
                cfg=ovl
            }
            ;;
        snp)
            missing_or_auto_case() {
                btrfs_snap=auto
            }
            ;;
    esac
    shift
    for _; do
        case "$1" in
            btrfs | ext[432] | f2fs | xfs)
                p_ptfsType=${1:-${p_ptfsType:-ext4}}
                ;;
            '' | auto) missing_or_auto_case "$1" ;;
            r[ow]:?*) btrfs_snap="$1" ;;
            subvol=?*) subvol=${1#subvol=} ;;
            subvolid=?*) subvolid=${1#subvolid=} ;;
            recreate=*)
                removePt="${1#recreate=}"
                removePt=$(readlink -f "$(label_uuid_to_dev "$removePt")" 2> /dev/kmsg)
                [ -b "$removePt" ] || {
                    [ "$p_pt" ] && removePt="$p_pt"
                }
                ;;
            serial=?*)
                ISS=${1%%/serial/*}
                diskDevice=$(ID_SERIAL_SHORT_to_disc "${ISS#serial=}")
                ln -sf "$diskDevice" /run/initramfs/diskdev
                get_partitionTable "$diskDevice"
                ptSpec=${1#*/serial/}
                [ "$ptSpec" ] && {
                    case "$ptSpec" in
                        *[!0-9]* | 0*)
                            # Anything but a positive integer:
                            p_pt=$(label_uuid_to_dev "$ptSpec")
                            ;;
                        *)
                            p_pt=$(aptPartitionName "$diskDevice" "$partNbr")
                            ;;
                    esac
                }
                ;;
            mklabel)
                mklabel=gpt
                ESP=$(aptPartitionName "$diskDevice" 1)
                ln -sf "$ESP" /run/initramfs/espdev
                espStart=1
                ;;
            ropt)
                cfg="$1"
                ;;
            iso | ciso)
                cfg="$1"
                [ -h /run/initramfs/isofile ] && isofile=$(readlink -f /run/initramfs/isofile)
                ;;
            new_pt_for:*)
                # New overlay partition for an existing ovl_dir:
                base_dir="${1##*:}"
                cfg=ovl:"${1%:*}"
                # Trigger default ovlpath specification.
                rd_overlay=''
                ;;
            esp=*)
                szESP=${1#esp=}
                espStart=1
                ;;
            ea=?*)
                extra_attrs="${*}"
                extra_attrs=${extra_attrs#ea=}
                break
                # ea,extra attribute,s must be the final arguments.
                ;;
            PROMPTDK | PROMPTPT)
                prompt_for_device "${1#PROMPT}"
                ;;
            PROMPTDR)
                prompt_for_path "$1"
                ;;
            PROMPTFS)
                # Assigns fsType and rootflags.
                prompt_for_fstype
                ;;
            PROMPTSZ)
                # Assigns size.
                prompt_for_size "$1"
                ;;
            [1-9]% | [1-9][0-9]%)
                size="$1"
                ;;
            [1-9][Gg] | [1-9][0-9][Gg] | [1-9][0-9][0-9][MmGg] | [1-9][0-9][0-9][0-9][MmGg])
                size="$1"
                ;;
            *[!0-9]* | 0*)
                # Anything but a positive integer:
                case "$1" in
                    *=?*)
                        unset -v 'volatile'
                        p_pt="$(label_uuid_to_dev "${1%%:*}")"
                        ln -sf "$p_pt" /run/initramfs/p_pt
                        strstr "$1" ":" && {
                            ovlpath=${1##*:}
                            ln -sf "$ovlpath" /run/initramfs/ovlpath
                        }
                        ;;
                    *) ovlfs_name="$1" ;;
                esac
                ;;
            *)
                # any positive integer:
                size=$1
                ;;
        esac
        shift
    done
}

