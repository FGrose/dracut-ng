#!/bin/bash

# called by dracut
check() {
    # a live host-only image doesn't really make a lot of sense
    [[ $hostonly ]] && return 1
    return 255
}

# called by dracut
depends() {
    # Determine distribution in order to select
    #   the appropriate <distribution>-live-lib dependency.
    local dist
    dist=$(get_os_release_datum ID)
    dist=${dist#\"}
    dist=${dist%\"}

    # if dmsetup is not installed, then we cannot support fedora/red hat
    # style live images
    echo dm rootfs-block img-lib overlayfs initqueue partition-lib "${dist:-distribution}"-lib distribution-lib
    return 0
}

# called by dracut
installkernel() {
    hostonly='' instmods squashfs loop iso9660 erofs
}

# called by dracut
install() {
    inst_multiple umount dmsetup blkid dd losetup lsblk find rmdir stat
    inst_multiple -o checkisomd5
    inst_hook cmdline 30 "$moddir/parse-dmsquash-live.sh"
    inst_hook cmdline 31 "$moddir/parse-iso-scan.sh"
    inst_hook pre-udev 30 "$moddir/dmsquash-live-genrules.sh"
    inst_hook pre-udev 30 "$moddir/dmsquash-liveiso-genrules.sh"
    inst_hook pre-pivot 52 "$moddir/dmsquash-live-pre-pivot-actions.sh"
    inst_hook pre-shutdown 30 "$moddir/dmsquash-live-pre-shutdown.sh"
    inst_script "$moddir/dmsquash-live-root.sh" "/sbin/dmsquash-live-root"
    inst_script "$moddir/iso-scan.sh" "/sbin/iso-scan"
    inst_script "$moddir/../74rootfs-block/mount-root.sh" "/sbin/mount-root"
    if dracut_module_included "systemd"; then
        inst_script "$moddir/dmsquash-generator.sh" "$systemdutildir"/system-generators/dracut-dmsquash-generator
        inst_simple "$moddir/checkisomd5@.service" "/etc/systemd/system/checkisomd5@.service"
    fi
}
