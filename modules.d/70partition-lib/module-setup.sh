#!/bin/bash

check() {
    return 255
}

installkernel() {
    instmods btrfs ext4 fat xfs
}

install() {
    inst_multiple blkid mkdir mount parted rmdir umount
    inst_multiple -o mkfs.btrfs mkfs.ext4 mkfs.fat mkfs.xfs
    inst_simple "$moddir/partition-lib.sh" "/lib/partition-lib.sh"
}
