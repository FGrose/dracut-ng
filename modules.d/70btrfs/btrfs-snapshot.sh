#!/bin/sh

[ "$RD_DEBUG" = yes ] && set -x
if [ "$BASH" ]; then
    PS4='+ $(IFS=" " read -r u0 _ </proc/uptime; echo "$u0") $BASH_SOURCE@$LINENO ${FUNCNAME:+$FUNCNAME()}: '
else
    PS4='+ $0@$LINENO: '
fi
command -v getarg > /dev/null || . /lib/dracut-lib.sh
command -v mount_partition > /dev/null || . /lib/overlayfs-lib.sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$1" ] || exit 1
root_pt="$1"

ln -sf "$root_pt" /run/initramfs/rorootfs

# Mount the base root filesystem read-write.
fstype=btrfs srcPartition="$root_pt" mountPoint=/run/rootfsbase \
    srcflags="$rflags" mount_partition
mount -o remount,rw /run/rootfsbase
findmnt /run/rootfsbase > /dev/null 2>&1 || Die "Unable to mount $root_pt."

[ -d /run/rootfsbase/.snapshots ] || btrfs subvolume create /run/rootfsbase/.snapshots

btrfs_snap="$(readlink /run/initramfs/btrfs_snap)"
case "$btrfs_snap" in
    auto)
        date_ID=$(date +"%Y-%b-%d-%a-%H:%M:%S")
        btrfs subvolume snapshot /run/rootfsbase /run/rootfsbase/.snapshots/"$date_ID"
        btrfs subvolume snapshot -r /run/rootfsbase/.snapshots/"$date_ID" /run/rootfsbase/.snapshots/"$date_ID"-origin
        local label="$(blkid "$root_pt")"
        label="${label#* LABEL=\"}"
        label="${label%%\"*}"
        message="\`
\`   btrfs snapshots from: $root_pt ($label) /.snapshots
\`
\`           Select the snapshot # to be booted.
\`
\` #    Snapshot Name
\`\`0 - 'parent <FS_TREE>'
"
        command -v prompt_for_path > /dev/null || . /lib/partition-lib.sh
        plymouth --ping > /dev/null 2>&1 && {
            PLYMOUTH=PLYMOUTH
            . /lib/plymouth-lib.sh
        }
        echo 'Press <Escape> to toggle menu, then Enter the # for your target here' > /tmp/prompt
        prompt_for_path "$message" /run/rootfsbase/.snapshots /run/rootfsbase/.snapshots/*
        subvol="${objSelected#\'}"
        ;;
    r[ow]:?*)
        subvol="${btrfs_snap#*:}"
        [ "${btrfs_snap%%:*}" = rw ] || ro=ro
        btrfs subvolume snapshot ${ro:+-r} /run/rootfsbase /run/rootfsbase/.snapshots/"$subvol"
        ;;
esac
subvol=/run/rootfsbase/.snapshots/"${subvol%\'}"

snap_volid=$(btrfs inspect-internal rootid "$subvol")
btrfs subvolume set-default "$snap_volid" /run/rootfsbase
case "$(btrfs property get -ts "$subvol")" in
    ro=true)
        umount /run/rootfsbase
        # Use OverlayFS mount for read-only snapshot.
        load_fstype overlay || Die 'OverlayFS is required but unavailable.'

        p_pt=$(readlink -f /run/initramfs/p_pt)
        if [ -b "$p_pt" ]; then
            [ "${DRACUT_SYSTEMD-}" ] || {
                command -v det_fs > /dev/null || . /lib/fs-lib.sh
                command -v set_FS_opts > /dev/null || . /lib/distribution-lib.sh
                set_FS_opts "$(det_fs "$p_pt")" p_ptFlags
            }
            fstype="$p_ptfsType" srcPartition="$p_pt" mountPoint=/run/os_persist \
                srcflags="$p_ptFlags" mount_partition
        else
            mkdir -p /etc/kernel
            printf '%s' " rd.overlayfs=${ovlfs_name-os_snapfs}" >> /etc/kernel/cmdline
        fi
        # Mount snapshot as rootfsbase.
        fstype=btrfs srcPartition="$root_pt" mountPoint=/run/rootfsbase \
            srcflags="$rflags",ro mount_partition
        ;;
    *)
        umount /run/rootfsbase
        ln -sf "$root_pt" /run/initramfs/rorootfs
        if [ "${DRACUT_SYSTEMD-}" ]; then
            mount -t btrfs -o defaults"${rflags:+,"$rflags"}" "$root_pt" "$NEWROOT"
        else
            fstype=btrfs srcPartition="$root_pt" \
                mountPoint="$NEWROOT" srcflags="$rflags" \
                fsckoptions="$fsckoptions" mount_partition
        fi
        ;;
esac
ln -s null /dev/root

exit 0
