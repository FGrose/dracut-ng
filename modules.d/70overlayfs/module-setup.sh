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
    dracut_module_included dmsquash-live || {
        if dracut_module_included "systemd-initrd"; then
            inst_script "$moddir/overlayfs-generator.sh" "$systemdutildir"/system-generators/dracut-overlayfs-generator
        fi
        inst_hook cmdline 30 "$moddir/parse-overlayfs.sh"
        inst_hook pre-udev 30 "$moddir/overlayfs-genrules.sh"
        inst_script "$moddir/root-overlayfs.sh" "/sbin/root-overlayfs"
        inst md5sum
        dracut_need_initqueue
    }
    inst_simple "$moddir/overlayfs-lib.sh" "/lib/overlayfs-lib.sh"
    inst_hook pre-mount 01 "$moddir/prepare-overlayfs.sh"
    inst_hook mount 01 "$moddir/mount-overlayfs.sh"     # overlay on top of block device
    if dracut_module_included "systemd-initrd"; then
        inst_script "$moddir/../74rootfs-block/mount-root.sh" "/sbin/mount-root"
    else
        inst_hook pre-pivot 10 "$moddir/mount-overlayfs.sh" # overlay on top of network device (e.g. nfs)
    fi
    inst_hook pre-pivot 51 "$moddir/overlayfs-pre-pivot-actions.sh"
}
