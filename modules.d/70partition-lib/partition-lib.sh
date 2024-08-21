#!/bin/sh
# partition-lib.sh: utilities for partition editing

gatherData() {
    if [ -z "$overlay" ]; then
        info "Skipping overlay creation: kernel command line parameter 'rd.live.overlay' is not set"
        return 1
    fi
    if ! str_starts "${overlay}" LABEL=; then
        die "Overlay creation failed: the partition must be set by LABEL in the 'rd.live.overlay' kernel parameter"
    fi

    overlayLabel=${overlay#LABEL=}
    if [ -b "/dev/disk/by-label/${overlayLabel}" ]; then
        info "Skipping overlay creation: overlay already exists"
        return 1
    fi

    filesystem=$(getarg rd.live.overlay.cowfs)
    [ -z "$filesystem" ] && filesystem="ext4"
    if [ "$filesystem" != "ext4" ] && [ "$filesystem" != "xfs" ] && [ "$filesystem" != "btrfs" ]; then
        die "Overlay creation failed: only ext4, xfs, and btrfs are supported in the 'rd.live.overlay.cowfs' kernel parameter"
    fi

    currentPartitionCount=$(grep --count -E "${diskDevice#/dev/}[0-9]+" /proc/partitions)

    freeSpaceStart=$(parted --script "${diskDevice}" --fix unit % print free \
        | awk -v "x=${currentPartitionCount}" '$1 == x {getline; print $1}')
    if [ -z "$freeSpaceStart" ]; then
        info "Skipping overlay creation: there is no free space after the last partition"
        return 1
    fi
    partitionStart=$((${freeSpaceStart%.*} + 1))
    if [ $partitionStart -eq 100 ]; then
        info "Skipping overlay creation: there is not enough free space after the last partition"
        return 1
    fi

    overlayPartition=$(aptPartitionName "${diskDevice}" $((currentPartitionCount + 1)))
}

createPartition() {
    parted --script --align optimal "${diskDevice}" mkpart primary ${partitionStart}% 100%
}

createFilesystem() {
    "mkfs.${filesystem}" -L "${overlayLabel}" "${overlayPartition}"

    baseDir=/run/initramfs/create-overlayfs
    mkdir -p ${baseDir}
    mount -t "${filesystem}" "${overlayPartition}" ${baseDir}

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
