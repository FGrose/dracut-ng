#!/bin/sh

[ "$RD_DEBUG" = yes ] && set -x
if [ "$BASH" ]; then
    PS4='+ $(IFS=" " read -r u0 _ </proc/uptime; echo "$u0") $BASH_SOURCE@$LINENO ${FUNCNAME:+$FUNCNAME()}: '
else
    PS4='+ $0@$LINENO: '
fi
PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$1" ] || exit 1
root_pt="$1"

plymouth --ping > /dev/null 2>&1 && {
    PLYMOUTH=PLYMOUTH
    . /lib/plymouth-lib.sh
}

# Based on function in partition-lib.sh
prompt_for_input() {
    local - obj _list
    set +x
    PROMPT='Press <Escape> to toggle menu, then Enter the # for your target here'
    [ "$PLYMOUTH" ] || _list="
${warn:+"$warn
"}$list
"
    {
        flock -s 9
        while [ "${obj:-#}" = '#' ]; do
            printf "\033c" > /dev/console
            dmesg -D
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "${warn:+"$warn
"}$list
Press <Escape> to toggle to/from your target selection menu."
                REPLY=$(plymouth ask-question --prompt="$PROMPT")
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/console
                REPLY=$(systemd-ask-password --echo=yes --timeout=0 "${PROMPT#Press <Escape> to toggle menu, then }":)
            else
                printf '%s' "${_list}${PROMPT#Press <Escape> to toggle menu, then }: " > /dev/console
                read -r
            fi
            dmesg -E
            case_block
            case "$obj" in
                continue)
                    unset -v 'obj'
                    continue
                    ;;
            esac
            end_block
        done
    } 9> /.console_lock
    echo "$obj"
    objSelected="$obj"
    return 0
}

# Prompt for directory contents based on input glob "$@"
# $1=<header message>
# $2=<mountpoint directory>[/<directory path>]
# $3=<input glob> $@
#  sets variable objSelected
prompt_for_path() {
    local - o p i j warn message="$1" dir="$2"
    set +x
    list="${message}
\` #    Snapshot Name
\`\`0 - 'parent <FS_TREE>'
"
    shift 2
    # paths from glob
    for p; do
        j=$((j + 1))
        i=$j
        if [ "$j" -lt 10 ]; then
            i=\`\`$i
        elif [ "$j" -lt 100 ]; then
            i=\`$i
        fi
        p="${p#*"$dir"/}"
        o="'${p#/}'"
        list="$list$i - ${o}
"
    done

    case_block() {
        case "$REPLY" in
            0) obj='../' ;;
            '' | *[!0-9]* | 0[0-9]*) obj='continue' ;;
        esac
    }

    end_block() {
        if [ "$REPLY" -lt 10 ]; then
            REPLY=\`\`$REPLY
        elif [ "$REPLY" -lt 100 ]; then
            REPLY=\`$REPLY
        fi
        obj=${list#*"${REPLY} - '"}
        obj="${obj%%[\`\'|
]*}"
    }

    prompt_for_input
}

rflags=$rflags,rw
mkdir -p /run/rootfsbase
mount -t btrfs -o "$rflags" "$root_pt" /run/rootfsbase
findmnt /run/rootfsbase > /dev/null 2>&1 || Die "Unable to mount $root_pt."

[ -d /run/rootfsbase/.snapshots ] || btrfs subvolume create /run/rootfsbase/.snapshots
date_ID=$(date +"%Y-%b-%d-%a-%H:%M:%S")
btrfs subvolume snapshot /run/rootfsbase /run/rootfsbase/.snapshots/"$date_ID"
btrfs subvolume snapshot -r /run/rootfsbase/.snapshots/"$date_ID" /run/rootfsbase/.snapshots/"$date_ID"-origin

message="\`
\`   btrfs snapshots from: $root_pt ($(lsblk -no LABEL "$root_pt")) /.snapshots
\`
\`           Select the snapshot # to be booted.
\`"
prompt_for_path "$message" /run/rootfsbase/.snapshots /run/rootfsbase/.snapshots/*
subvol="${objSelected#\'}"
subvol=/run/rootfsbase/.snapshots/"${subvol%\'}"

snap_volid=$(btrfs inspect-internal rootid "$subvol")
btrfs subvolume set-default "$snap_volid" /run/rootfsbase
case "$(btrfs property get -ts "$subvol")" in
    ro=true)
        # Use OverlayFS mount for read-only snapshot.
        command -v getarg > /dev/null || . /lib/dracut-lib.sh
        getargbool 0 rd.overlayfs || {
            mkdir -p /etc/kernel
            printf '%s' " rd.overlayfs " >> /etc/kernel/cmdline
        }
        umount /run/rootfsbase
        [ "${DRACUT_SYSTEMD-}" ] && systemctl mask sysroot.mount
        /sbin/root-overlayfs "$root_pt"
        ;;
    *)
        [ "$snap_volid" = 5 ] || btrfs property set "$subvol" compression zstd:3
        umount /run/rootfsbase
        [ "${DRACUT_SYSTEMD-}" ] || {
            # Repurpose 99-mount-root.sh for the root partition.
            mntcmd="$hookdir"/mount/99-mount-root.sh
            fstype=btrfs srcPartition="$root_pt" mountPoint="$NEWROOT" srcflags="$rflags" "$mntcmd" override
        }
        ln -s null /dev/root
        ;;
esac

exit 0
