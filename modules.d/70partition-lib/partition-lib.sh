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

gatherData() {
    if [ -z "$rd_live_overlay" ]; then
        info "Skipping overlay creation: kernel command line parameter 'rd.live.overlay' is not set"
        return 1
    fi
    if ! str_starts "${rd_live_overlay}" LABEL=; then
        die "Overlay creation failed: the partition must be set by LABEL in the 'rd.live.overlay' kernel parameter"
    fi

    overlayLabel=${rd_live_overlay#LABEL=}
    if [ -b "/dev/disk/by-label/${overlayLabel}" ]; then
        info "Skipping overlay creation: overlay already exists"
        return 1
    fi

    filesystem=$(getarg rd.live.overlay.cowfs)
    [ -z "$filesystem" ] && filesystem="ext4"
    if [ "$filesystem" != "ext4" ] && [ "$filesystem" != "xfs" ] && [ "$filesystem" != "btrfs" ]; then
        die "Overlay creation failed: only ext4, xfs, and btrfs are supported in the 'rd.live.overlay.cowfs' kernel parameter"
    fi

    get_partitionTable
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
        --align optimal mkpart "$overlayLabel" "${partitionStart}B" 100% \
        type "$newPtNbr" ccea7cb3-70ba-4c31-8455-b906e46a00e2 \
        set "$newPtNbr" no_automount on
}

createFilesystem() {
    "mkfs.${filesystem}" -L "${overlayLabel}" "${p_Partition}"

    baseDir=/run/initramfs/create-overlayfs
    mkdir -p ${baseDir}
    mount -t "${filesystem}" "${p_Partition}" ${baseDir}

    mkdir -p "${baseDir}/${live_dir}/ovlwork"
    mkdir "${baseDir}/${live_dir}/overlay-${label}-${uuid}"

    umount ${baseDir}
    rm -r ${baseDir}
}

prep_Partition() {
    if gatherData "$1"; then
        createPartition
        udevsettle
        createFilesystem
        udevsettle
    fi
}
