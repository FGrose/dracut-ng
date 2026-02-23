#!/bin/sh

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
                : ${p_ptfsType:=ext4}
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
            tmpfs:*)
                parse_tmpfs_opts "$1"
                ;;
            size=* | nr_blocks=* | nr_inodes=*)
                parse_tmpfs_opts "$1"
                ;;
            new_pt_for:*)
                # New overlay partition for an existing ovl_dir:
                base_dir="${1##*:}"
                cfg=ovl:"${1%:*}"
                # Trigger default ovlpath specification.
                rd_overlay=''
                ;;
            PROMPTDK | PROMPTPT)
                [ "$SYSTEMD_IN_INITRD" = 1 ] || prompt_for_device "${1#PROMPT}"
                ;;
            PROMPTDR)
                [ "$SYSTEMD_IN_INITRD" = 1 ] || prompt_for_path "$1"
                ;;
            PROMPTFS)
                # Assigns fsType and rootflags.
                [ "$SYSTEMD_IN_INITRD" = 1 ] || prompt_for_fstype
                ;;
            PROMPTSZ)
                # Assigns sizeGiB.
                [ "$SYSTEMD_IN_INITRD" = 1 ] || prompt_for_size
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
                        unset -v 'cfg'
                        strstr "$1" ":" && {
                            ovlpath=${1##*:}
                            echo "$ovlpath" > /run/initramfs/ovlpath
                        }
                        ;;
                    *) OverlayFS="$1" ;;
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
