#!/bin/sh
# partition-lib.sh: utilities for partition editing

plymouth --ping > /dev/null 2>&1 && {
    export PLYMOUTH=PLYMOUTH
    . /lib/plymouth-lib.sh
}

run_parted() {
    LC_ALL=C flock "$1" parted --script "$@"
}

# Set partitionTable, szDisk variables for diskDevice=$1
# partitionTable holds values for the latest call to this function.
get_partitionTable() {
    local -
    set +x
    : "${fix=yes}"
    partitionTable="$(run_parted "$1" ${fix:+--fix} -m unit B print free 2> /dev/kmsg)"
    szDisk="${partitionTable#*"$1":}"
    szDisk="${szDisk%%B*}"
    fix=''
    [ "$szDisk" = ' unrecognised disk label
' ] && {
        # Includes case of raw, unpartitioned disk.
        run_parted "$1" -m mklabel gpt || Die "Failed to make partition table on $1."
        get_partitionTable "$1"
    }
}

# for partitionTable ptNbr/leading_field_string_pattern=$1
pt_row() {
    local b
    # shellcheck disable=SC2295 # pattern matching desired
    b=${partitionTable#"${partitionTable%
$1:*}"
}
    if [ "$1" = 1 ]; then
        # For first partition, remove any leading free space record.
        b=${partitionTable#*free;
1:}
        if [ "$b" = "$partitionTable" ]; then
            # greedy tail removal
            # shellcheck disable=SC2295 # pattern matching desired
            b=${partitionTable#"${partitionTable%%
$1:*}"
}
        else
            b="1:$b"
        fi
    fi
    [ "$b" = "$partitionTable" ] || echo "${b%%
*}"
}

parse_pt_row() {
    [ ! "$@" ] || {
        # shellcheck disable=SC2068
        set -- $@
        ptNbr=$1
        ptStart=${2%B}
        ptEnd=${3%B}
        ptLength=${4%B}
        ptFStype=$5
        ptLabel=$6
        ptFlags=${7%;}
    }
}

# $@ - $newptCmd
get_newptNbr() {
    set -- "$@"
    IFS=: parse_pt_row "$(pt_row "?*:$5")"
    newptNbr="$ptNbr"
}

# Default case block for prompt_for_input().
case_block() {
    case "$REPLY" in
        '' | *[!0-9]* | 0[0-9]*) obj='continue' ;;
        break) obj='break' ;;
    esac
}

# Default end block for prompt_for_input().
end_block() {
    if [ "$REPLY" -lt 10 ]; then
        REPLY=\`\`$REPLY
    elif [ "$REPLY" -lt 100 ]; then
        REPLY=\`$REPLY
    fi
    obj=${list#*"${REPLY} - "}
    obj="${obj%%[\`|
]*}"
}

# Core prompt function for prompt_for_* functions below.
#  $PROMPT retrieved from /tmp/prompt
#  $list provides menu content, $warn, header info.
prompt_for_input() {
    local - obj _list
    set +x
    [ "$PLYMOUTH" ] || _list="
${warn:+"$warn
"}$list
"
    {
        flock -s 9
        while [ "${obj:-#}" = '#' ]; do
            printf "\033c" > /dev/console
            dmesg -D
            read -r PROMPT < /tmp/prompt
            : "${PROMPT:=Enter the # for your selection here: }"
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "${warn:+"$warn
"}$list
Press <Escape> to toggle to/from the selection menu."
                REPLY=$(plymouth ask-question --prompt="$PROMPT")
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/console
                REPLY=$(systemd-ask-password --echo=yes --timeout=0 "${PROMPT#Press <Escape> to toggle menu, then }")
            else
                printf '%s' "${_list}${PROMPT#Press <Escape> to toggle menu, then } " > /dev/console
                read -r REPLY
            fi
            dmesg -E
            case_block
            case "$obj" in
                continue)
                    unset -v 'obj'
                    continue
                    ;;
                break)
                    break
                    ;;
            esac
            end_block
        done
    } 9> /.console_lock
    echo "$obj"
    objSelected="$obj"
    return 0
}

# Prompt for new partition size.
prompt_for_size() {
    local - OLDIFS space _warn sz_max
    set +x
    [ "$partitionTable" ] || get_partitionTable "$diskDevice"
    space=$(lsblk -o PATH,MODEL,PARTLABEL,LABEL,FSTYPE,SIZE "$diskDevice")
    OLDIFS="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $partitionTable
    IFS=':'
    # shellcheck disable=SC2046
    set -- $(eval printf '%s:' $\{$#\})
    sz_max=$((${4%B} >> 30))
    IFS="$OLDIFS"
    # shellcheck disable=SC2086
    set -- $partitionTable
    IFS=':'
    # shellcheck disable=SC2046
    set -- $(eval printf '%s:' $\{$#\})
    sz_max=$((${4%B} >> 30))
    IFS="$OLDIFS"
    _warn='`
`   Enter a size in GiBytes for the new persistence partition.
`
`   Below is the current partitioning.
`'
    [ "$PLYMOUTH" ] || _list="
$_warn
$space
\`
\`   $sz_max GiB is the upper limit.
"
    echo "Enter a whole number (GiB) for the partition size (max=$sz_max GiB) here: " > /tmp/prompt
    case_block() {
        [ "$REPLY" -gt "$sz_max" ] && echo "
            That's too large..." && REPLY=''
        case "$REPLY" in
            break) obj='break' ;;
            '' | *[!0-9]* | 0[0-9]* | 0*) obj='continue' ;;
        esac
    }
    end_block() {
        obj="$REPLY"
    }
    prompt_for_input
    size="$objSelected"
    return 0
}

# Prompt for a new partition fstype and set rootflags.
prompt_for_fstype() {
    local - i t fslist _warn
    set +x
    set -- btrfs ext4 f2fs xfs
    i=0
    for t; do
        [ -x /usr/sbin/mkfs."$t" ] && {
            fslist="$fslist
$i - $t"
            i=$((i + 1))
        }
    done
    _warn='`
`   Enter the number for the filesystem type of the new partition.'
    list="
$_warn
$fslist
"
    echo 'Enter a number for your fstype here: ' > /tmp/prompt
    case_block() {
        case "$REPLY" in
            '' | *[!0-9]* | 0[0-9]*) obj='continue' ;;
            [0-3]) : ;;
            *) obj='continue' ;;
        esac
    }
    end_block() {
        obj="${list#*"$REPLY" - }"
        obj="${obj%%
*}"
    }
    prompt_for_input
    p_ptfsType="$objSelected"
    set_FS_options "$p_ptfsType"
    return 0
}

parse_cfgArgs() {
    local -
    set -x
    # shellcheck disable=SC2068
    set -- $@ # rd_live_overlay
    IFS=' 	
'
    for _; do
        case "$1" in
            '' | btrfs | ext[432] | f2fs | xfs)
                p_ptfsType=${1:-${p_ptfsType:-ext4}}
                ;;
            recreate=*)
                removePt="${1#recreate=}"
                removePt=$(readlink -f "$(label_uuid_to_dev "$removePt")" 2> /dev/kmsg)
                [ -b "$removePt" ] || {
                    [ "$p_Partition" ] && removePt="$p_Partition"
                }
                ;;
            ea=?*)
                extra_attrs="${*}"
                extra_attrs=${extra_attrs#ea=}
                break
                # ea,extra attribute,s must be the final arguments.
                ;;
            PROMPTSZ)
                # Assigns sizeGiB.
                prompt_for_size "$1"
                ;;
            PROMPTFS)
                # Assigns fsType and rootflags.
                prompt_for_fstype
                ;;
            *[!0-9]* | 0*)
                # Anything but a positive integer:
                [ "$1" = auto ] || p_Partition=$(label_uuid_to_dev "${1%%:*}")
                strstr "$1" ":" && ovlpath=${1##*:}
                ;;
            *)
                # any positive integer:
                sizeGiB=$1
                ;;
        esac
        shift
    done
}

prep_Partition() {
    local n removePtNbr freeSpaceStart freeSpaceEnd byteMax
    [ "$p_Partition" ] && ! [ -b "$p_Partition" ] \
        && Die "The specified persistence partition, $p_Partition, is not recognized."
    if [ "$p_Partition" ] && ! [ "$removePt" ]; then
        info "Skipping overlay creation: a persistence partition already exists."
        rd_live_overlay="$p_Partition"
        ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.live.overlay=$p_Partition rd.live.overlay.overlayfs"
        return 0
    elif [ ! "$rd_live_overlay" ]; then
        info "Skipping overlay creation: kernel command line parameter 'rd.live.overlay' is not set."
        return 1
    fi
    freeSpaceEnd=$((szDisk - 1048576))
    [ "$removePt" ] && {
        [ "${removePt#"$diskDevice"}" = "$removePt" ] && {
            # removePt NOT on diskDevice.
            # shellcheck disable=SC2046
            set -- $(lsblk -nrpo PKNAME,OPT-IO "$removePt")
            diskDevice="$1"
            optimalIO="$2"
            get_partitionTable "$diskDevice"
        }
        removePtNbr="${removePt#"$diskDevice"}"
        removePtNbr="${removePtNbr#p}"
        IFS=: parse_pt_row "$(pt_row "$removePtNbr")"
        freeSpaceStart=$ptStart
        # Next row has free space?
        IFS=: parse_pt_row "$(pt_row "1:$((ptEnd + 1))B")"
        freeSpaceEnd=$ptEnd
        # Previous row has free space?
        IFS=: parse_pt_row "$(pt_row "1:*B:$((freeSpaceStart - 1))B")"
        [ "$ptStart" -gt "$freeSpaceStart" ] || freeSpaceStart=$ptStart
        [ $((freeSpaceEnd - freeSpaceStart + 1)) -gt 268435456 ] || {
            warn "Skipping partition recreation: less than 256 MiB of space would be available."
            return 1
        }
        byteMax=$freeSpaceEnd
    }
    OLDIFS="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $partitionTable
    IFS=:
    # shellcheck disable=SC2046
    set -- $(eval printf '%s:' $\{$(($# - 1))\})
    IFS="$OLDIFS"

    # dd'd iso first boot situations.
    case "$6" in
        Gap1)
            # Remove artifactual partition in Fedora 37-41 distribution .iso
            removePtNbr=$1
            freeSpaceStart=${2%B}
            ;;
    esac
    [ "$removePt" ] || {
        freeSpaceStart=$((${3%B} + 1))
        byteMax=$((szDisk - 268435456))
    }

    # Make optimalIO alignment at least 4 MiB.
    #   See https://www.gnu.org/software/parted/manual/parted.html#FOOT2 .
    [ "${optimalIO:-0}" -lt 4194304 ] && optimalIO=4194304

    # Set optimalIO address for partition start - $1, variable - $2
    optimize() {
        eval "$2"=$((($1 + optimalIO - 1) / optimalIO * optimalIO))
    }

    partitionStart=$freeSpaceStart
    optimize "$partitionStart" partitionStart

    if [ "$partitionStart" -gt "$byteMax" ]; then
        # Allow at least 256 MiB for persistence partition.
        warn "Skipping partition creation: less than 256 MiB of space is available."
        return 1
    fi
    sizeGiB=${sizeGiB:+$((sizeGiB << 30))}
    partitionEnd="$((partitionStart + ${sizeGiB:-$szDisk} - 512))"
    [ "$partitionEnd" -gt "$freeSpaceEnd" ] && partitionEnd=$freeSpaceEnd

    run_parted "$diskDevice" --fix ${removePtNbr:+rm $removePtNbr} \
        "${newptCmd:=--align optimal mkpart LiveOS_persist "${partitionStart}B" "${partitionEnd}B"}"

    # LiveOS persistence partition type
    newptType=ccea7cb3-70ba-4c31-8455-b906e46a00e2

    # Set new partition type with command - $@
    set_pt_type() {
        get_partitionTable "$diskDevice"
        get_newptNbr "$@"
        run_parted "$diskDevice" type "$newptNbr" "$newptType" \
            set "$newptNbr" no_automount on
    }
    # shellcheck disable=SC2086
    set_pt_type $newptCmd

    p_Partition=$(aptPartitionName "$diskDevice" "$newPtNbr")
    udevadm trigger --name-match "$p_Partition" --action add --settle > /dev/null 2>&1
    ln -sf "$p_Partition" /run/initramfs/p_pt

    set_FS_opts_w "${fsType:-ext4}" p_ptFlags
    mkfs_config "${p_ptfsType:=ext4}" LiveOS_persist $((partitionEnd - partitionStart + 1)) "${extra_attrs}"
    wipefs --lock -af${QUIET:+q} "$p_Partition"
    create_Filesystem "$p_ptfsType" "$p_Partition"
}
