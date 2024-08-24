#!/bin/sh
# partition-lib.sh: utilities for partition editing

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
        run_parted "$1" -m mklabel gpt || die "Failed to make partition table on $1."
        get_partitionTable "$1"
    }
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
            '' | btrfs | ext[432] | xfs)
                fsType=${1:-${fsType:-ext4}}
                ;;
            [!0-9]* | 0*)
                # Anything but a positive integer:
                [ "$1" = auto ] || p_Partition=$(label_uuid_to_dev "${1%%:*}")
                strstr "$1" ":" && ovlpath=${1##*:}
                ;;
        esac
        shift
    done
}

gatherData() {
    [ "$p_Partition" ] && [ ! -b "$p_Partition" ] \
        && die "The specified persistence partition, $p_Partition, is not recognized."

    # Assign persistence partition fsType
    case "${fsType:=ext4}" in
        btrfs | ext[432] | xfs) ;;
        *)
            die "Partition creation halted: only filesystems btrfs|ext[432]|xfs
                   are supported by the 'rd.live.overlay=[<fstype>[,...]]]' command line parameter."
            ;;
    esac

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
        eval "$2"=$((($1 + optimalIO - 1) / optimalIO * optimalIO))
    }

    partitionStart=$freeSpaceStart
    optimize "$partitionStart" partitionStart

    if [ $partitionStart -gt $((szDisk - (1 << 28))) ]; then
        # Allow at least 256 MiB for persistence partition.
        info "Skipping overlay creation: there is less than 256 MiB of free space after the last partition"
        return 1
    fi

    p_Partition=$(aptPartitionName "${diskDevice}" "$newPtNbr")
}

createPartition() {
    # LiveOS persistence partition type
    run_parted "$diskDevice" --fix ${removePtNbr:+rm $removePtNbr} \
        --align optimal mkpart LiveOS_persist "${partitionStart}B" 100% \
        type "$newPtNbr" ccea7cb3-70ba-4c31-8455-b906e46a00e2 \
        set "$newPtNbr" no_automount on
}

createFilesystem() {
    "mkfs.${fsType}" -L LiveOS_persist "${p_Partition}"

    mount -m -t "${fsType}" "${p_Partition}" ${mntDir:=/run/initramfs/LiveOS_persist}

    mkdir -p "${mntDir}/${live_dir}/ovlwork" "${mntDir}/${ovlpath}"

    umount ${mntDir}
}

prep_Partition() {
    if gatherData "$1"; then
        createPartition
        udevsettle
        createFilesystem
        udevsettle
    fi
}
