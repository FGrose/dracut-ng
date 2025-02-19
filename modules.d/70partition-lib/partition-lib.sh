#!/bin/sh
# partition-lib.sh: utilities for partition editing

plymouth --ping > /dev/null 2>&1 && {
    export PLYMOUTH=PLYMOUTH
    . /lib/plymouth-lib.sh
}

run_parted() {
    LC_ALL=C flock "$1" parted --script "$@"
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
            [ "${2#/dev/loop}" = "$2" ] || return 0
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
}

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

# Prompt for $1 - DK | PT
#           [$2] - message
#           [$3] - warnx (warning line)
#  Sets variable diskDevice or pt_dev for partition.
prompt_for_device() {
    local - OLDIFS discs d i j device dev list _list listNbr sep message warnx warn warn0 warnz
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
    discs=$(lsblk -"$d"po PATH,LABEL,SIZE,MODEL,SERIAL,TYPE /dev/sd? /dev/nvme??? /dev/mmcblk? 2> /dev/kmsg)
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
`#'
                sep=' '
                ;;
            disk)
                sep=-
                [ "$device" = partition ] && {
                    i='`.'
                    sep='.'
                }
                ;;
            *)
                sep=-
                ;;
        esac
        [ "$sep" = - ] && {
            i=$j
            [ "$j" -lt 10 ] && i=\`$i
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
    [ "$PLYMOUTH" ] || _list="
$warn
$list
Enter the number for your target $device here: "

    {
        flock -s 9
        while :; do
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "$warn
$list
Press <Escape> to toggle to/from your disc selection menu."
                listNbr=$(plymouth ask-question --prompt="Enter the number for your target $device here")
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/kmsg
                listNbr=$(systemd-ask-password --echo=yes --timeout=0 "Enter the number for your target $device here:")
            else
                read -p "$_list" -r listNbr
            fi
            case "$listNbr" in
                '') return 1 ;;
                *[!0-9]*) continue ;;
            esac
            [ "$listNbr" -lt 10 ] && listNbr=\`$listNbr
            dev="${list#*
"$listNbr" - }"
            dev="${dev%% *}"
            [ "$dev" = '`
`#' ] || break
        done
    } 9> /.console_lock
    case "$device" in
        disc)
            diskDevice=$dev
            ;;
        partition)
            pt_dev=$dev
            get_diskDevice "$pt_dev"
            ;;
    esac
    get_partitionTable "$diskDevice"
    echo "$dev"
    return 0
}

# Prompt for directory contents based on input glob "$@"
# $1=<header message>
# $2=<mountpoint directory>[/<directory path>]
# $3=<input glob $@
#  sets variable objSelected
prompt_for_path() {
    local - o p i j list listNbr obj message="$1" dir="$2"
    set +x
    list="${message}
\` #   SIZE   NAME
"
    shift 2
    for p; do
        j=$((j + 1))
        i=$j
        if [ "$j" -lt 10 ]; then
            i=\`\`$i
        elif [ "$j" -lt 100 ]; then
            i=\`$i
        fi
        p="$(ls -1hs --quoting-style=shell-always "$p")"
        o="${p%% *}"
        p="${p#*"$dir"/}"
        o="${o}  '${p#/}"
        list="$list$i - ${o}
"
    done
    [ "$PLYMOUTH" ] || _list="
$list
Enter the number for your target path here: "
    {
        flock -s 9
        while [ "${obj:-#}" = '#' ]; do
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "$list
Press <Escape> to toggle to/from your path selection menu."
                listNbr=$(plymouth ask-question --prompt="Enter the number for your target file here")
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/kmsg
                listNbr=$(systemd-ask-password --echo=yes --timeout=0 "Enter the number for your target file here:")
            else
                read -p "$_list" -r listNbr
            fi
            case "$listNbr" in
                '') return 1 ;;
                *[!0-9]* | 0[0-9]*) continue ;;
            esac
            if [ "$listNbr" -lt 10 ]; then
                listNbr=\`\`$listNbr
            elif [ "$listNbr" -lt 100 ]; then
                listNbr=\`$listNbr
            fi
            obj="${list#*
"$listNbr" - }"
            obj="${obj%%
*}"
            obj="${obj##* }"
        done
    } 9> /.console_lock
    echo "$obj"
    objSelected="$obj"
    return 0
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
    [ "$removePt" ] || {
        freeSpaceStart=$((${3%B} + 1))
        byteMax=$((szDisk - 268435456))
    }

    # Make optimalIO alignment at least 4 MiB.
    #   See https://www.gnu.org/software/parted/manual/parted.html#FOOT2 .
    [ "${optimalIO:-0}" -lt 4194304 ] && optimalIO=4194304

    # Set optimalIO address for partition start - $1, variable - $2
    optimize() {
        [ $(($1 % optimalIO)) -gt 0 ] \
            && eval "$2"=$((($1 / optimalIO + 1) * optimalIO))
    }

    partitionStart=$freeSpaceStart
    optimize "$partitionStart" partitionStart

    if [ "$partitionStart" -gt "$byteMax" ]; then
        # Allow at least 256 MiB for persistence partition.
        warn "Skipping partition creation: less than 256 MiB of space is available."
        return 1
    fi
    sizeGiB=${sizeGiB:+$((sizeGiB << 30))}
    partitionEnd="$((partitionStart + ${sizeGiB:-$szDisk} - 512))"
    [ "$partitionEnd" -gt "$freeSpaceEnd" ] && partitionEnd=$freeSpaceEnd

    run_parted "$diskDevice" --fix ${removePtNbr:+rm $removePtNbr} \
        ${newptCmd:=--align optimal mkpart LiveOS_persist "${partitionStart}B" "${partitionEnd}B"}

    # LiveOS persistence partition type
    newptType=ccea7cb3-70ba-4c31-8455-b906e46a00e2

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
    udevadm trigger --name-match "$p_Partition" --action add --settle > /dev/null 2>&1
    ln -sf "$p_Partition" /run/initramfs/p_pt

    set_FS_options "${fsType:-ext4}"
    mkfs_config "${p_ptfsType:=ext4}" LiveOS_persist $((partitionEnd - partitionStart + 1)) "${extra_attrs}"
    wipefs --lock -af${QUIET:+q} "$p_Partition"
    create_Filesystem "$p_ptfsType" "$p_Partition"
}
