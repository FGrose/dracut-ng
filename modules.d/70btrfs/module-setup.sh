#!/bin/bash

# called by dracut
check() {
    # if we don't have btrfs installed on the host system,
    # no point in trying to support it in the initramfs.
    require_binaries btrfs || return 1

    [[ $hostonly ]] || [[ $mount_needs ]] && {
        for fs in "${host_fs_types[@]}"; do
            [[ $fs == "btrfs" ]] && return 0
        done
        return 255
    }

    return 0
}

# called by dracut
depends() {
    echo udev-rules initqueue overlayfs
    return 0
}

# called by dracut
cmdline() {
    # Hack for slow machines
    # see https://github.com/dracutdevs/dracut/issues/658
    printf " rd.driver.pre=btrfs"
}

# called by dracut
installkernel() {
    hostonly='' instmods btrfs
}

# called by dracut
install() {
    # 64-btrfs.rules is shipped by udev/eudev, and it must always be installed
    # by the udev-rules module even if the btrfs module is not installed, to
    # mark btrfs devices ready or not.
    # See 567c4557537fe7f477f0f54237df00ebc79e56be

    inst_rules 64-btrfs-dm.rules

    if ! dracut_module_included "systemd"; then
        inst_hook initqueue/timeout 10 "$moddir/btrfs_timeout.sh"
    fi

    inst_multiple -o btrfsck btrfs-zero-log btrfstune
    inst date
    inst_binary /etc/localtime
    inst btrfs /sbin/btrfs
    inst_hook cmdline 99 "$moddir"/parse-btrfs-snapshot.sh
    inst_hook pre-udev 31 "$moddir"/btrfs-snapshot-genrules.sh
    inst_script "$moddir"/btrfs-snapshot.sh /sbin/btrfs-snapshot
    inst_hook pre-mount 51 "$moddir"/btrfs-snapshot-premount-actions.sh

    if [[ $hostonly_cmdline == "yes" ]]; then
        printf "%s\n" "$(cmdline)" > "${initdir}/etc/cmdline.d/20-btrfs.conf"
    fi
}
