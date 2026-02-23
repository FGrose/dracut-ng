#!/bin/sh
# partition-lib-min.sh:
# core functions for minimal sourcing, such as for early boot generators.

# Additional mount flags appended to any from the command line for fsType.
# Set default mkfs extra attributes, if none from the command line.
# $1 - fsType
# $2 - flag_var (p_ptFlags or rflags)
set_FS_options() {
    local - fsType="$1" flag_var="$2" param flags
    set -x
    case "$flag_var" in
        p_ptFlags) param=rd.ovl.flags ;;
        rflags) param=rootflags ;;
    esac
    flags=$(getarg "$param")
    case "$fsType" in
        btrfs)
            [ "$subvol" ] && flags="${flags:+$flags,}subvol=$subvol"
            flags="${flags:+$flags,}"compress=zstd:3
            ;;
        f2fs)
            case "${extra_attrs:=extra_attr,inode_checksum,sb_checksum,compression}" in
                *compression*) flags="${flags:+$flags,}"compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge ;;
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
    read -r "$flag_var" <<EOF
$flags
EOF
}

# Call with IFS=, parse_cfgArgs $1="<cfg>,<comma-separated input string>"
#   $1 becomes $@
parse_cfgArgs() {
    local - auto_case
    set -x
    # shellcheck disable=SC2068
    set -- $@
    IFS=' 	
'
    # Parse key=value pairs from rd.overlay=tmpfs:key=val,
    parse_tmpfs_opts() {
        local - _param _key _val
        set -f
        _param=${1#tmpfs:}
        _key="${_param%%=*}"
        _val="${_param#*=}"
        case "$_key" in
            size | nr_blocks | nr_inodes)
                ovltmpfsopts="${ovltmpfsopts:+${ovltmpfsopts},}${_key}=${_val}"
                ;;
            *)
                warn "Unknown tmpfs option '${_key}', ignoring."
                ;;
        esac
        [ "$ovltmpfsopts" ] && echo "$ovltmpfsopts" > /run/initramfs/ovltmpfsopts
    }
        
    case "$1" in
        ovl | img)
            auto_case() {
                p_ptfsType=${1:-${p_ptfsType:-ext4}}
                OverlayFS=LiveOS_rootfs
                espStart=1
            }
            cfg="$1"
            ;;
        snp)
            auto_case() {
                btrfs_snap=auto
            }
            ;;
    esac
    shift
    [ $# -eq 0 ] && {
        set -- LiveOS_rootfs
        unset -v 'cfg'
    }
    while [ $# -gt 0 ]; do
        case "$1" in
            btrfs | ext[432] | f2fs | xfs)
                p_ptfsType=${1:-${p_ptfsType:-ext4}}
                ;;
            auto) auto_case ;;
            r[ow]:?*) btrfs_snap="$1" ;;
            subvol=?*) subvol=${1#subvol=} ;;
            subvolid=?*) subvolid=${1#subvolid=} ;;
            tmpfs:*)
                parse_tmpfs_opts "$1"
                ;;
            size=* | nr_blocks=* | nr_inodes=*)
                parse_tmpfs_opts "$1"
                ;;
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
                echo "$diskDevice" > /run/initramfs/diskdev
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
            new_pt_for:*)
                # New overlay partition for an existing ovl_dir:
                base_dir="${1##*:}"
                cfg=ovl:"${1%:*}"
                # Trigger default ovlpath specification.
                rd_overlay=''
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
                prompt_for_size
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
