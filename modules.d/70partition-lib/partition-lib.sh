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
# partitionTable hold values for latest call to this function.
get_partitionTable() {
    local -
    set +x
    partitionTable="$(run_parted "$1" -m unit B print free 2> /dev/kmsg)"
    szDisk="${partitionTable#*"$1":}"
    szDisk="${szDisk%%B*}"
    [ "$szDisk" = ' unrecognised disk label
' ] && {
        # Includes case of raw, unpartitioned disk.
        run_parted "$1" -m mklabel gpt || Die "Failed to make partition table on $1."
        get_partitionTable "$1"
    }
}

# Prompt for new partition size.
prompt_for_size() {
    local - OLDIFS space warn sz sz_max
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
    warn='`
`   Enter a size in GiBytes for the new persistence partition.
`
`   Below is the current partitioning.
`'
    [ "$PLYMOUTH" ] || _list="
$warn
$space
\`
\`   $sz_max GiB is the upper limit.
Enter a whole number for the partition size here: 
"
    {
        flock -s 9
        while :; do
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "$warn
$space
\`
\`   $sz_max GiB is the upper limit.
Press <Escape> to toggle to/from the partition display."
                sz=$(plymouth ask-question --prompt='Enter a whole number for the partition size here')
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/kmsg
                sz=$(systemd-ask-password --echo=yes --timeout=0 "Enter a whole number (GiB) for the partition size here (max=$sz_max GiB): ")
            else
                read -p "$_list" -r sz
            fi
            [ "$sz" -gt "$sz_max" ] && echo "
                That's too large..." && continue
            case "$sz" in
                '') continue ;;
                break) break ;;
                *[!0-9]* | 0[0-9]* | 0*) continue ;;
                *) break ;;
            esac
        done
    } 9> /.console_lock
    echo "$sz"
    sizeGiB="$sz"
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
    [ "$p_Partition" ] && [ ! -b "$p_Partition" ] \
        && Die "The specified persistence partition, $p_Partition, is not recognized."
    if [ "$p_Partition" ]; then
        info "Skipping overlay creation: a persistence partition already exists."
        rd_live_overlay="$p_Partition"
        ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.live.overlay=$p_Partition rd.live.overlay.overlayfs"
        return 0
    elif [ ! "$rd_live_overlay" ]; then
        info "Skipping overlay creation: kernel command line parameter 'rd.live.overlay' is not set."
        return 1
    fi
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
            ;;
    esac
    if [ "$removePtNbr" ]; then
        freeSpaceStart=${2%B}
        newPtNbr=$1
    else
        freeSpaceStart=$((${3%B} + 1))
        newPtNbr=$(($1 + 1))
    fi

    # Make optimalIO alignment at least 4 MiB.
    #   See https://www.gnu.org/software/parted/manual/parted.html#FOOT2 .
    [ "${optimalIO:-0}" -lt 4194304 ] && optimalIO=4194304

    # Set optimalIO address for partition start - $1, variable - $2
    optimize() {
        [ $(($1 % optimalIO)) -gt 0 ] \
            && eval "$2"=$((($1 / optimalIO + 1) * optimalIO))
    }

    partitionStart=$freeSpaceStart
    optimize "$partitionStart" partitionStart

    if [ $partitionStart -gt $((szDisk - 268435456)) ]; then
        # Allow at least 256 MiB for persistence partition.
        info "Skipping overlay creation: there is less than 256 MiB of free space after the last partition"
        return 1
    fi
    local freeSpaceEnd
    freeSpaceEnd=$((szDisk - 1048576))
    sizeGiB=${sizeGiB:+$((sizeGiB << 30))}
    partitionEnd="$((partitionStart + ${sizeGiB:-$szDisk} - 512))"
    [ "$partitionEnd" -gt "$freeSpaceEnd" ] && partitionEnd=$freeSpaceEnd

    p_Partition=$(aptPartitionName "${diskDevice}" "$newPtNbr")

    # LiveOS persistence partition type
    run_parted "$diskDevice" --fix ${removePtNbr:+rm $removePtNbr} \
        --align optimal mkpart LiveOS_persist "${partitionStart}B" "${partitionEnd}B" \
        type "$newPtNbr" ccea7cb3-70ba-4c31-8455-b906e46a00e2 \
        set "$newPtNbr" no_automount on
    udevadm trigger --name-match "$p_Partition" --action add --settle > /dev/null 2>&1

    set_FS_options "${fsType:-ext4}"
    mkfs_config "${p_ptfsType:=ext4}" LiveOS_persist $((partitionEnd - partitionStart + 1)) "${extra_attrs}"
    wipefs --lock -af${QUIET:+q} "$p_Partition"
    create_Filesystem "$p_ptfsType" "$p_Partition"
}
