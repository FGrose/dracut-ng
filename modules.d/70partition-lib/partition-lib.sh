#!/bin/sh
# partition-lib.sh: utilities for partition editing

plymouth --ping > /dev/null 2>&1 && {
    export PLYMOUTH=PLYMOUTH
    . /lib/plymouth-lib.sh
}

run_parted() {
    LC_ALL=C flock "$1" parted --script "$@"
}

<<<<<<< HEAD
=======
# call in this fashion:
#   src=<source image file or block device>
#   dst=<destination path>
#     [var=<name of variable holding the destination path>]
#     [sz=<image size in bytes>]
#     [msg=<message text for copy to persistent media>] dd_copy
dd_copy() {
    local src dst var sz msg ddir
    ddir=${dst%/*}
    [ "$(findmnt -nro FSTYPE -T "$ddir")" = tmpfs ] && {
        src=$(readlink -f "$src")
        [ "$sz" ] || sz=$(blkid --probe --match-tag FSSIZE --output value --usages filesystem "$src")
        check_live_ram "$((sz >> 20))"
    }

    echo "Copying $src ${msg:=to RAM...}" > /dev/kmsg
    echo ' (this may take a minute or so)' > /dev/kmsg
    LC_ALL=C flock "$ddir" dd if="$src" of="$dst" ${sz:+count="${sz}"B} bs=8M iflag=nocache oflag=direct status=progress 2> /dev/kmsg
    eval "${var:=_}=$dst"
    echo "Done copying $src $msg" > /dev/kmsg
}

# Determine some attributes for the device - $1
get_diskDevice() {
    local dev n ls_dev
    dev="$1"
    ls_dev="lsblk -dnpro TYPE,PKNAME,OPT-IO,FSTYPE $dev"
    # shellcheck disable=SC2046
    set -- $($ls_dev 2>&1)
    until [ "$1" != lsblk: ] || [ ${n:=0} -gt 9 ]; do
        sleep 0.4
        n=$((n + 1))
        # shellcheck disable=SC2046
        set -- $($ls_dev 2>&1)
    done
    case "$1" in
        disk)
            diskDevice="$dev"
            shift
            ;;
        part)
            diskDevice="$2"
            shift 2
            ;;
        loop)
            return 0
            ;;
        lsblk:)
            # shellcheck disable=SC3028,SC2128
            Die "get_diskDevice() failed near $BASH_SOURCE@LINENO:$((LINENO - 18)) ${FUNCNAME:+$FUNCNAME()} 
    > $* <"
            ;;
    esac
    optimalIO="$1"
    fsType="$2"
    ln -sf "$diskDevice" /run/initramfs/diskdev
}

>>>>>>> fb7e8df0b (feat(dmsquash-live): provide & employ dd copy image function)
# Set partitionTable, szDisk variables for diskDevice=$1
# partitionTable hold values for latest call to this function.
get_partitionTable() {
    local -
    set +x
    partitionTable="$(run_parted "$1" -m unit B print free 2> /dev/kmsg)"
    szDisk="${partitionTable#*"$1":}"
    szDisk="${szDisk%%B*}"
    [ "$szDisk" = ' unrecognised disk label
' ] && {
        # Includes case of raw, unpartitioned disk.
        run_parted "$1" -m mklabel gpt || Die "Failed to make partition table on $1."
        get_partitionTable "$1"
    }
}

# for partitionTable ptNbr/leading_field_string_pattern=$1
pt_row() {
    local b
    # shellcheck disable=SC2295 # pattern matching desired
    b=${partitionTable#"${partitionTable%
$1:*}"
}
    if [ "$1" = 1 ]; then
        # For first partition, remove any leading free space record.
        b=${partitionTable#*free;
1:}
        if [ "$b" = "$partitionTable" ]; then
            # greedy tail removal
            # shellcheck disable=SC2295 # pattern matching desired
            b=${partitionTable#"${partitionTable%%
$1:*}"
}
        else
            b="1:$b"
        fi
    fi
    [ "$b" = "$partitionTable" ] || echo "${b%%
*}"
}

parse_pt_row() {
    [ ! "$@" ] || {
        # shellcheck disable=SC2068
        set -- $@
        ptNbr=$1
        ptStart=${2%B}
        ptEnd=${3%B}
        ptLength=${4%B}
        ptFStype=$5
        ptLabel=$6
        ptFlags=${7%;}
    }
}

# $@ - $newptCmd
get_newptNbr() {
    set -- "$@"
    IFS=: parse_pt_row "$(pt_row "?*:$5")"
    newptNbr="$ptNbr"
}

# Find the overlay's partition and assign variables & link.
get_LiveOS_persist() {
    local -
    set +x
    [ "$partitionTable" ] || get_partitionTable "$1"
    espNbr=${partitionTable%"${partitionTable#* esp;}"}
    espRow="${espNbr##*;
}"
    espNbr=${espRow%%:*}
    ESP=$(aptPartitionName "$1" "$espNbr")
    ln -sf "$ESP" /run/initramfs/espdev
}

# Default case block for prompt_for_input().
case_block() {
    case "$REPLY" in
        '' | *[!0-9]* | 0[0-9]*) obj='continue' ;;
    esac
}

# Default end block for prompt_for_input().
end_block() {
    if [ "$REPLY" -lt 10 ]; then
        REPLY=\`\`$REPLY
    elif [ "$REPLY" -lt 100 ]; then
        REPLY=\`$REPLY
    fi
    obj=${list#*"${REPLY} - "}
    obj="${obj%%[\`|
]*}"
}

# Core prompt function for prompt_for_* functions below.
#  $PROMPT retrieved from /tmp/prompt
prompt_for_input() {
    local - obj _list
    set +x
    [ "$PLYMOUTH" ] || _list="
${warn:+"$warn
"}$list
"
    {
        flock -s 9
        while [ "${obj:-#}" = '#' ]; do
            printf "\033c" > /dev/console
            dmesg -D
            read -r PROMPT < /tmp/prompt
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
                read -r REPLY
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

# from diskDevice $1
get_ESP() {
    local -
    set +x
    [ "$partitionTable" ] || get_partitionTable "$1"
    espNbr=${partitionTable%"${partitionTable#* esp;}"}
    espRow="${espNbr##*;
}"
    espNbr=${espRow%%:*}
    ESP=$(aptPartitionName "$1" "$espNbr")
    ln -sf "$ESP" /run/initramfs/espdev
}

# Prompt for $1 - DK | PT
#           [$2] - message
#           [$3] - warnx (warning line)
#  Sets variable diskDevice or pt_dev for partition.
prompt_for_device() {
    local - OLDIFS discs d i j device dev list _list sep message warnx warn warn0 warnz
    case "${1-PT}" in
        DK)
            # Assign diskDevice.
            message=${2-'
`
`   Select the installation target disk.
`'}
            device=disc
            d=d
            ;;
        PT)
            # Assign partition
            message=${2-'
`
`   Select the installation target partition.
`'}
            device=partition
            ;;
    esac
    warnx="$3"
    set +x
    discs=$(lsblk -"${d:+$d}"po PATH,LABEL,SIZE,MODEL,SERIAL,TYPE /dev/sd? /dev/nvme??? /dev/mmcblk? 2> /dev/kmsg)
    OLDIFS="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $discs
    IFS="$OLDIFS"
    j=1
    for d; do
        case "${d##* }" in
            TYPE)
                i='`
``#'
                sep=' '
                ;;
            disk)
                sep=-
                [ "$device" = partition ] && {
                    i='``.'
                    sep='.'
                }
                ;;
            *)
                sep=-
                ;;
        esac
        [ "$sep" = - ] && {
            i=$j
            if [ "$j" -lt 10 ]; then
                i=\`\`$i
            elif [ "$j" -lt 100 ]; then
                i=\`$i
            fi
            j=$((j + 1))
        }
        list="$list$i $sep ${d% *}
"
    done
    warn='`
`                  >>> >>> >>>       WARNING       <<< <<< <<<
`                  >>>    Choose your target carefully!    <<<'
    warn0='`                  >>>   A wrong choice will destroy the   <<<
`                  >>>      contents of a whole disc!      <<<'
    warnz='`                  >>> >>> >>>                     <<< <<< <<<'
    case "$warnx" in
        warn0)
            warn=''
            warn0=''
            ;;
        *)
            warnx="$warn0"
            ;;
    esac
    warn="$warn
$warn0
$warnz$message"

    echo "Enter the # for your target $device here: " > /tmp/prompt

    prompt_for_input

    dev="${objSelected%% *}"
    case "$device" in
        disc)
            diskDevice=$dev
            ln -sf "$diskDevice" /run/initramfs/diskdev
            ;;
        partition)
            pt_dev=$dev
            get_diskDevice "$pt_dev"
            ;;
    esac
    get_partitionTable "$diskDevice"
}

# Prompt for directory contents based on input glob "$@"
# $1=<header message>
# $2=<mountpoint directory>[/<directory path>]
# $3=<input glob $@
#  sets variable objSelected
prompt_for_path() {
    local - o p i j warn message="$1" dir="$2"
>>>>>>> fb7e8df0b (feat(dmsquash-live): provide & employ dd copy image function)
    set -x
    p_Partition=''
    ptNbr=''
    IFS=: parse_pt_row "$(pt_row "*:LiveOS_persist")"
    [ "$ptNbr" ] && {
        p_Partition=$(aptPartitionName "$diskDevice" "$ptNbr")
        ln -sf "$p_Partition" /run/initramfs/p_pt
        p_ptfsType="$ptFStype"
    }
}

# Prompt for new partition size.
prompt_for_size() {
    local - OLDIFS space warn sz sz_max
    set +x
    [ "$partitionTable" ] || get_partitionTable "$diskDevice"
    space=$(lsblk -o PATH,MODEL,PARTLABEL,LABEL,FSTYPE,SIZE "$diskDevice")
    OLDIFS="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $partitionTable
    IFS=':'
    # shellcheck disable=SC2046
    set -- $(eval printf '%s:' $\{$#\})
    sz_max=$((${4%B} >> 30))
    IFS="$OLDIFS"
    # shellcheck disable=SC2086
    set -- $partitionTable
    IFS=':'
    # shellcheck disable=SC2046
    set -- $(eval printf '%s:' $\{$#\})
    sz_max=$((${4%B} >> 30))
    IFS="$OLDIFS"
    warn='`
`   Enter a size in GiBytes for the new persistence partition.
`
`   Below is the current partitioning.
`'
    [ "$PLYMOUTH" ] || _list="
$warn
$space
\`
\`   $sz_max GiB is the upper limit.
Enter a whole number for the partition size here: 
"
    {
        flock -s 9
        while :; do
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "$warn
$space
\`
\`   $sz_max GiB is the upper limit.
Press <Escape> to toggle to/from the partition display."
                sz=$(plymouth ask-question --prompt='Enter a whole number for the partition size here')
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/kmsg
                sz=$(systemd-ask-password --echo=yes --timeout=0 "Enter a whole number (GiB) for the partition size here (max=$sz_max GiB): ")
            else
                read -p "$_list" -r sz
            fi
            [ "$sz" -gt "$sz_max" ] && echo "
                That's too large..." && continue
            case "$sz" in
                '') continue ;;
                break) break ;;
                *[!0-9]* | 0[0-9]* | 0*) continue ;;
                *) break ;;
            esac
        done
    } 9> /.console_lock
    echo "$sz"
    sizeGiB="$sz"
    return 0
}

parse_cfgArgs() {
    local -
    set -x
    # shellcheck disable=SC2068
    set -- $@ # rd_live_overlay
    IFS=' 	
'
    for _; do
        case "$1" in
            '' | btrfs | ext[432] | f2fs | xfs)
                p_ptfsType=${1:-${p_ptfsType:-ext4}}
                ;;
            recreate=*)
                removePt="${1#recreate=}"
                removePt=$(readlink -f "$(label_uuid_to_dev "$removePt")" 2> /dev/kmsg)
                [ -b "$removePt" ] || {
                    [ "$p_Partition" ] && removePt="$p_Partition"
                }
                ;;
            serial=?*)
                ISS=${1%%/serial/*}
                diskDevice=$(ID_SERIAL_SHORT_to_disc "${ISS#serial=}")
                ln -sf "$diskDevice" /run/initramfs/diskdev
                get_partitionTable "$diskDevice"
                ptSpec=${1#*/serial/}
                [ "$ptSpec" ] && {
                    case "$ptSpec" in
                        *[!0-9]* | 0*)
                            # Anything but a positive integer:
                            p_Partition=$(label_uuid_to_dev "$ptSpec")
                            ;;
                        *)
                            p_Partition=$(aptPartitionName "$diskDevice" "$partNbr")
                            ;;
                    esac
                }
                ;;
            auto)
                espStart=1
                cfg=ovl
                ;;
            ea=?*)
                extra_attrs="${*}"
                extra_attrs=${extra_attrs#ea=}
                break
                # ea,extra attribute,s must be the final arguments.
                ;;
            PROMPTSZ)
                # Assigns sizeGiB.
                prompt_for_size "$1"
                ;;
            *[!0-9]* | 0*)
                # Anything but a positive integer:
                [ "$1" = auto ] || p_Partition=$(label_uuid_to_dev "${1%%:*}")
                strstr "$1" ":" && ovlpath=${1##*:}
                ;;
            *)
                # any positive integer:
                sizeGiB=$1
                ;;
        esac
        shift
    done
}

prep_Partition() {
    local n removePtNbr freeSpaceStart freeSpaceEnd byteMax
    [ "$p_Partition" ] && ! [ -b "$p_Partition" ] \
        && Die "The specified persistence partition, $p_Partition, is not recognized."
    if [ "$p_Partition" ] && ! [ "$removePt" ]; then
        info "Skipping overlay creation: a persistence partition already exists."
        rd_live_overlay="$p_Partition"
        ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.live.overlay=$p_Partition rd.live.overlay.overlayfs"
        return 0
    elif [ ! "$rd_live_overlay" ]; then
        info "Skipping overlay creation: kernel command line parameter 'rd.live.overlay' is not set."
        return 1
    fi
    freeSpaceEnd=$((szDisk - 1048576))
    [ "$removePt" ] && {
        [ "${removePt#"$diskDevice"}" = "$removePt" ] && {
            # removePt NOT on diskDevice.
            # shellcheck disable=SC2046
            set -- $(lsblk -nrpo PKNAME,OPT-IO "$removePt")
            diskDevice="$1"
            optimalIO="$2"
            get_partitionTable "$diskDevice"
        }
        removePtNbr="${removePt#"$diskDevice"}"
        removePtNbr="${removePtNbr#p}"
        IFS=: parse_pt_row "$(pt_row "$removePtNbr")"
        freeSpaceStart=$ptStart
        # Next row has free space?
        IFS=: parse_pt_row "$(pt_row "1:$((ptEnd + 1))B")"
        freeSpaceEnd=$ptEnd
        # Previous row has free space?
        IFS=: parse_pt_row "$(pt_row "1:*B:$((freeSpaceStart - 1))B")"
        [ "$ptStart" -gt "$freeSpaceStart" ] || freeSpaceStart=$ptStart
        [ $((freeSpaceEnd - freeSpaceStart + 1)) -gt 268435456 ] || {
            warn "Skipping partition recreation: less than 256 MiB of space would be available."
            return 1
        }
        byteMax=$freeSpaceEnd
    }
    OLDIFS="$IFS"
    IFS='
'
    # shellcheck disable=SC2086
    set -- $partitionTable
    IFS=:
    # shellcheck disable=SC2046
    set -- $(eval printf '%s:' $\{$(($# - 1))\})
    IFS="$OLDIFS"

    # dd'd iso first boot situations.
    case "$6" in
        Gap1)
            # Remove artifactual partition in Fedora 37-41 distribution .iso
            removePtNbr=$1
            freeSpaceStart=${2%B}
            ;;
    esac
    [ "$removePt" ] || freeSpaceStart=$((${3%B} + 1))
    byteMax=$((szDisk - 268435456))

    # Make optimalIO alignment at least 4 MiB.
    #   See https://www.gnu.org/software/parted/manual/parted.html#FOOT2 .
    [ "${optimalIO:-0}" -lt 4194304 ] && optimalIO=4194304

    # Set optimalIO address for partition start - $1, variable - $2
    optimize() {
        [ $(($1 % optimalIO)) -gt 0 ] \
            && eval "$2"=$((($1 / optimalIO + 1) * optimalIO))
    }
    [ "$espStart" ] && {
        # Format ESP.
        espStart=${2%B}
        freeSpaceStart=$((espStart + (${szESP:=$(get_sz_forESP)} << 20) + 1))

        optimize "$espStart" espStart

        if [ -d /run/initramfs/isoscan ]; then
            isoscandev="$(readlink -f /run/initramfs/isoscandev)"
            isofile="$(readlink -f /run/initramfs/isofile)"
        fi
    }

    partitionStart=$freeSpaceStart
    optimize "$partitionStart" partitionStart

    [ "$espStart" ] && {
        espCmd="rm ${espNbr:=1}"
        espCmd="${espCmd:+rm "$espNbr"} --align optimal mkpart ESP fat32 ${espStart}B $((partitionStart - 1))B \
            type $espNbr c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    }

    if [ "$partitionStart" -gt "$byteMax" ]; then
        # Allow at least 256 MiB for persistence partition.
        warn "Skipping partition creation: less than 256 MiB of space is available."
        return 1
    fi
    sizeGiB=${sizeGiB:+$((sizeGiB << 30))}
    partitionEnd="$((partitionStart + ${sizeGiB:-$szDisk} - 512))"
    [ "$partitionEnd" -gt "$freeSpaceEnd" ] && partitionEnd="$freeSpaceEnd"

    run_parted "$diskDevice" --fix ${removePtNbr:+rm $removePtNbr} \
        "${newptCmd:=--align optimal mkpart LiveOS_persist "${partitionStart}B" "${partitionEnd}B"}"

    # shellcheck disable=SC2086
    run_parted "${diskDevice}" --fix \
        ${removePtNbr:+rm "$removePtNbr"} \
        ${espCmd:+$espCmd} \
        ${newptCmd:=--align optimal mkpart "$live_dir".. "${partitionStart}"B "${partitionEnd}"B}
    : "${cfg:=ovl}"

    [ "$espCmd" ] && {
        udevadm trigger --name-match "$ESP" --action add --settle > /dev/kmsg 2>&1
        mkfs_config fat ESP $((partitionStart - espStart))
        create_Filesystem fat "$ESP"
    }

    if [ "$roptCmd" ]; then
        newptCmd="$roptCmd"
        # LiveOS read-only root filesystem partition type
        newptType=ba3b9999-09c7-4e11-92c4-05736aea8b95
    else
        newptCmd="$p_ptCmd"
        # LiveOS persistence partition type
        newptType=ccea7cb3-70ba-4c31-8455-b906e46a00e2
    fi
    # shellcheck disable=SC2086
    run_parted "${diskDevice}" --fix ${mklabel:+mklabel ${mklabel:=gpt}} \
        ${removePtNbr:+rm "$removePtNbr"} \
        ${espCmd:+$espCmd} \
        ${newptCmd}
    : "${cfg:=ovl}"

    # Set new partition type with command - $@
    set_pt_type() {
        get_partitionTable "$diskDevice"
        get_newptNbr "$@"
        run_parted "$diskDevice" type "$newptNbr" "$newptType" \
            set "$newptNbr" no_automount on
    }
    # shellcheck disable=SC2086
    set_pt_type $newptCmd

    p_Partition=$(aptPartitionName "$diskDevice" "$newPtNbr")
    udevadm trigger --name-match "$p_Partition" --action add --settle > /dev/kmsg 2>&1
    ln -sf "$p_Partition" /run/initramfs/p_pt

    [ "$p_ptFlags" ] || set_FS_opts "${fsType:-ext4}" p_ptFlags
    mkfs_config "${p_ptfsType:=ext4}" LiveOS_persist $((partitionEnd - partitionStart + 1)) "${extra_attrs}"
    wipefs --lock -af${QUIET:+q} "$p_Partition"
    create_Filesystem "$p_ptfsType" "$p_Partition"
}
