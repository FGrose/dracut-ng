#!/bin/bash

check() {
    require_binaries parted || return 1
    return 255
}

installkernel() {
    instmods btrfs ext4 fat f2fs xfs
}

install() {
    inst_multiple parted wipefs
    inst_multiple -o mkfs.btrfs mkfs.ext4 mkfs.fat mkfs.f2fs mkfs.xfs
    inst_simple "$moddir/partition-lib-min.sh" "/lib/partition-lib-min.sh"
    inst_simple "$moddir/partition-lib.sh" "/lib/partition-lib.sh"
}
