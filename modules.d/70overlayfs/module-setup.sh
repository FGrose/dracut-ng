#!/bin/bash

check() {
    require_kernel_modules overlay || return 1
    return 255
}

depends() {
    # Determine distribution in order to select
    #   the appropriate <distribution>-lib dependency.
    local dist
    dist=$(get_os_release_datum ID)
    dist=${dist#\"}
    dist=${dist%\"}

    echo base fs-lib initqueue "${dist:-distribution}"-lib distribution-lib
}

installkernel() {
    hostonly="" instmods overlay
}

install() {
    if dracut_module_included "systemd"; then
        inst_script "$moddir/overlayfs-generator.sh"  "$systemdutildir"/system-generators/dracut-overlayfs-generator
    else
        inst_hook mount 01 "$moddir/mount-overlayfs.sh"     # overlay on top of block device
    fi
    dracut_module_included dmsquash-live || {
        inst_hook cmdline 30 "$moddir/parse-overlayfs.sh"
        inst_script "$moddir/root-overlayfs.sh" "/sbin/root-overlayfs"
    }
    inst_simple "$moddir/overlayfs-lib.sh" "/lib/overlayfs-lib.sh"
    inst_hook pre-udev 30 "$moddir/overlayfs-genrules.sh"
    inst_hook pre-mount 01 "$moddir/prepare-overlayfs.sh"
    dracut_module_included net-lib && inst_hook pre-pivot 10 "$moddir/mount-overlayfs.sh" # overlay on top of network device (e.g. nfs)
    inst_hook pre-pivot 51 "$moddir/overlayfs-pre-pivot-actions.sh"
    inst_script "$moddir"/overlayfs-root_t.sh /sbin/overlayfs-root_t.sh
    inst_simple "$moddir"/overlayfs-root_t.service "$systemdsystemunitdir"/overlayfs-root_t.service    inst_hook pre-pivot 51 "$moddir/overlayfs-pre-pivot-actions.sh"
}
