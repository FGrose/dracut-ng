#!/bin/bash

check() {
    require_kernel_modules overlay || return 1
    return 255
}

depends() {
    echo base
}

installkernel() {
    hostonly="" instmods overlay
}

install() {
    inst_simple "$moddir/overlayfs-lib.sh" "/lib/overlayfs-lib.sh"
    inst_hook pre-mount 01 "$moddir/prepare-overlayfs.sh"
    dracut_module_included systemd || {
        inst_hook mount 01 "$moddir/mount-overlayfs.sh"     # overlay on top of block device
    }
    dracut_module_included net-lib && inst_hook pre-pivot 10 "$moddir/mount-overlayfs.sh" # overlay on top of network device (e.g. nfs)
    inst_hook pre-pivot 51 "$moddir/overlayfs-pre-pivot-actions.sh"
    inst_script "$moddir"/overlayfs-root_t.sh /sbin/overlayfs-root_t.sh
    inst_simple "$moddir"/overlayfs-root_t.service "$systemdsystemunitdir"/overlayfs-root_t.service
}
