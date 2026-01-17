#!/bin/sh
# partition-lib.sh: utilities for partition editing

command -v parse_cfgArgs > /dev/null || . /lib/partition-lib-min.sh

run_parted() {
    LC_ALL=C flock "$1" parted --script "$@"
}

# Copy image file or device with dd.
# call in this fashion:
#   src=<source image file or block device>
#   dst=<destination path>
#     [var=<name of variable holding the destination path>]
#     [sz=<image size in bytes>]
#     [msg=<message text for copy to persistent media>] dd_copy
dd_copy() {
    local src dst var sz msg ddir
    ddir=${dst%/*}
    [ "$ddir" != /dev ] && [ "$(stat -f -c %T "$ddir")" = tmpfs ] && {
        src=$(readlink -f "$src")
        [ "$sz" ] || sz=$(stat -c %s -- "$src")
        check_live_ram "$((sz >> 20))"
    }
    [ "$ddir" = /dev ] && ddir="$diskDevice"

    echo "Copying $src ${msg:=to RAM...}" > /dev/kmsg
    echo ' (this may take a minute or so)' > /dev/kmsg
    LC_ALL=C flock "$ddir" dd if="$src" of="$dst" ${sz:+count="${sz}"B} bs=8M iflag=nocache oflag=direct status=progress 2> /dev/kmsg
    eval "${var:=_}=$dst"
    echo "Done copying $src $msg" > /dev/kmsg
}

# Determine some attributes for the device - $1
get_diskDevice() {
    local - dev n syspath p_path
    set -x
    dev="${1##*/}"
    syspath=/sys/class/block/"$dev"
    n=0
    until [ -d "$syspath" ] || [ "$n" -gt 9 ]; do
        sleep 0.4
        n=$((n + 1))
    done
    [ -d "$syspath" ] || return 1
    if [ -f "$syspath"/partition ]; then
        p_path=$(readlink -f "$syspath"/..)
        diskDevice=/dev/"${p_path##*/}"
    else
        while read -r line; do
            case "$line" in
                DEVTYPE=disk) diskDevice=/dev/"$dev" ;;
                DEVTYPE=loop) return 0 ;;
            esac
        done < "$syspath"/uevent
    fi
    { read -r optimalIO < "$syspath"/queue/optimal_io_size; } > /dev/null 2>&1
    : "${optimalIO:=0}"
    fsType=$(blkid /dev/"$dev")
    fsType="${fsType#* TYPE=\"}"
    fsType="${fsType%%\"*}"
    ln -sf "$diskDevice" /run/initramfs/diskdev
}

# Set partitionTable, szDisk variables for diskDevice=$1
# partitionTable holds values for the latest call to this function.
get_partitionTable() {
    local -
    set +x
    : "${fix=yes}"
    partitionTable="$(run_parted "$1" ${fix:+--fix} -m unit B print free 2> /dev/kmsg)"
    szDisk="${partitionTable#*"$1":}"
    szDisk="${szDisk%%B*}"
    fix=''
    [ "$szDisk" = ' unrecognised disk label
' ] && {
        # Includes case of raw, unpartitioned disk.
        run_parted "$1" -m mklabel gpt || Die "Failed to make partition table on $1."
        get_partitionTable "$1"
    }
}

# for partitionTable {ptNbr|leading_field_string_pattern}=$1
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

# $1 - $diskDevice
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

# Recommended ESP size in MiB
get_sz_forESP() {
    if [ "$szDisk" -lt 34359738368 ]; then
        # Minimum ESP size of 512 MiB for disks smaller than 32 GiB.
        echo 512
    else
        # Provide ESP with 128 MiB of additional space per 16 GiB of free disk
        #  space for multi image boots.
        echo "$(((((szDisk - freeSpaceStart) / 17179869184) << 7) + 512))"
    fi
}

# Default case block for prompt_for_input().
case_block() {
    case "$REPLY" in
        '' | *[!0-9]* | 0[0-9]*) obj='continue' ;;
        break) obj='break' ;;
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
#  $list provides menu content, $warn, header info.
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
            : "${PROMPT:=Enter the # for your selection here: }"
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "${warn:+"$warn
"}$list
Press <Escape> to toggle to/from the selection menu."
                REPLY=$(plymouth ask-question --prompt="$PROMPT")
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/console
                REPLY=$(systemd-ask-password --echo=yes --timeout=0 "${PROMPT#Press <Escape> to toggle menu, then }")
            else
                printf '%s' "${_list}${PROMPT#Press <Escape> to toggle menu, then } " > /dev/console
                read -r REPLY
            fi
            dmesg -E
            case_block
            case "$obj" in
                continue)
                    unset -v 'obj'
                    continue
                    ;;
                break)
                    break
                    ;;
            esac
            end_block
        done
    } 9> /.console_lock
    echo "$obj"
    objSelected="$obj"
    return 0
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
# $3=<input glob> $@
#  sets variable objSelected
prompt_for_path() {
    local - o p i j warn message="$1" dir="$2"
    set +x
    list="${message}"
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

# Prompt for Live directory name
prompt_for_livedir() {
    local - d warn list
    set +x
    get_ESP "$diskDevice"
    # Some hardware devices need more time to respond in very early boot.
    sleep 0.1
    if mount -n -t vfat -m -o check=s "$ESP" /run/initramfs/ESP; then
        list='`
`  Installed LiveOS directories:'
        for d in /run/initramfs/ESP/*/images; do
            d=${d#*ESP/}
            d=${d%/images}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
        for d in /run/initramfs/ESP/*/boot; do
            d=${d#*ESP/}
            d=${d%/boot}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
    else
        list='To recognize your image installation,'
    fi
    if [ "$base_dir" ]; then
        list="$list
\`  For a new overlay for the system image '$base_dir',"
    else
        list="$list
\`  For the image labeled '$label',"
    fi
    echo 'Please enter a short, unique, & distinguishing Live directory name here:' > /tmp/prompt
    [ "$PLYMOUTH" ] || list="$list
\`"
    case_block() {
        case "$REPLY" in
            *[[:space:]]* | *[[:cntrl:]]* | '')
                echo "LiveDir '$REPLY' is null, has whitespace, or control characters; Please select another LiveDir name:" > /tmp/prompt
                ;;
            break)
                Die "Forced break from prompt_for_livedir()."
                ;;
            *)
                if [ -d /run/initramfs/ESP/"$REPLY" ]; then
                    echo "LiveDir '$REPLY' already exists; Please select another LiveDir name:" > /tmp/prompt
                else
                    [ "$base_dir" ] && srcdir=$base_dir
                    obj="$REPLY"
                fi
                ;;
        esac
    }

    end_block() {
        [ -b "$ESP" ] && umount /run/initramfs/ESP
        [ "$srcdir" = PROMPT ] && srcdir=LiveOS
        ln -sf "$REPLY" /run/initramfs/live_dir
    }
    prompt_for_input
}

# Prompt for Live directory name
prompt_for_livedir() {
    local - d warn list
    set +x
    get_ESP "$diskDevice"
    # Some hardware devices need more time to respond in very early boot.
    sleep 0.1
    if mount -n -t vfat -m -o check=s "$ESP" /run/initramfs/ESP; then
        list='`
`  Installed LiveOS directories:'
        for d in /run/initramfs/ESP/*/images; do
            d=${d#*ESP/}
            d=${d%/images}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
        for d in /run/initramfs/ESP/*/boot; do
            d=${d#*ESP/}
            d=${d%/boot}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
    else
        list='To recognize your image installation,'
    fi
    if [ "$base_dir" ]; then
        list="$list
\`  For a new overlay for the system image '$base_dir',"
    else
        list="$list
\`  For the image labeled '$label',"
    fi
    echo 'Please enter a short, unique, & distinguishing Live directory name here:' > /tmp/prompt
    [ "$PLYMOUTH" ] || list="$list
\`"
    case_block() {
        case "$REPLY" in
            *[[:space:]]* | *[[:cntrl:]]* | '')
                echo "LiveDir '$REPLY' is null, has whitespace, or control characters; Please select another LiveDir name:" > /tmp/prompt
                ;;
            break)
                Die "Forced break from prompt_for_livedir()."
                ;;
            *)
                if [ -d /run/initramfs/ESP/"$REPLY" ]; then
                    echo "LiveDir '$REPLY' already exists; Please select another LiveDir name:" > /tmp/prompt
                else
                    [ "$base_dir" ] && srcdir=$base_dir
                    obj="$REPLY"
                fi
                ;;
        esac
    }

    end_block() {
        [ -b "$ESP" ] && umount /run/initramfs/ESP
        [ "$srcdir" = PROMPT ] && srcdir=LiveOS
        ln -sf "$REPLY" /run/initramfs/ovl_dir
    }
    prompt_for_input
}

# Prompt for Live directory name
prompt_for_livedir() {
    local - d warn list
    set +x
    get_ESP "$diskDevice"
    # Some hardware devices need more time to respond in very early boot.
    sleep 0.1
    if mount -n -t vfat -m -o check=s "$ESP" /run/initramfs/ESP; then
        list='`
`  Installed LiveOS directories:'
        for d in /run/initramfs/ESP/*/images; do
            d=${d#*ESP/}
            d=${d%/images}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
        for d in /run/initramfs/ESP/*/boot; do
            d=${d#*ESP/}
            d=${d%/boot}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
    else
        list='To recognize your image installation,'
    fi
    if [ "$base_dir" ]; then
        list="$list
\`  For a new overlay for the system image '$base_dir',"
    else
        list="$list
\`  For the image labeled '$label',"
    fi
    echo 'Please enter a short, unique, & distinguishing Live directory name here:' > /tmp/prompt
    [ "$PLYMOUTH" ] || list="$list
\`"
    case_block() {
        case "$REPLY" in
            *[[:space:]]* | *[[:cntrl:]]* | '')
                echo "LiveDir '$REPLY' is null, has whitespace, or control characters; Please select another LiveDir name:" > /tmp/prompt
                ;;
            break)
                Die "Forced break from prompt_for_livedir()."
                ;;
            *)
                if [ -d /run/initramfs/ESP/"$REPLY" ]; then
                    echo "LiveDir '$REPLY' already exists; Please select another LiveDir name:" > /tmp/prompt
                else
                    [ "$base_dir" ] && srcdir=$base_dir
                    obj="$REPLY"
                fi
                ;;
        esac
    }

    end_block() {
        [ -b "$ESP" ] && umount /run/initramfs/ESP
        [ "$srcdir" = PROMPT ] && srcdir=LiveOS
        ln -sf "$REPLY" /run/initramfs/ovl_dir
    }
    prompt_for_input
}

# Prompt for Live directory name
prompt_for_livedir() {
    local - d warn list
    set +x
    get_ESP "$diskDevice"
    # Some hardware devices need more time to respond in very early boot.
    sleep 0.1
    if mount -n -t vfat -m -o check=s "$ESP" /run/initramfs/ESP; then
        list='`
`  Installed LiveOS directories:'
        for d in /run/initramfs/ESP/*/images; do
            d=${d#*ESP/}
            d=${d%/images}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
        for d in /run/initramfs/ESP/*/boot; do
            d=${d#*ESP/}
            d=${d%/boot}
            [ "$d" = "*" ] || list="$list
    \`  $d"
        done
    else
        list='To recognize your image installation,'
    fi
    if [ "$base_dir" ]; then
        list="$list
\`  For a new overlay for the system image '$base_dir',"
    else
        list="$list
\`  For the image labeled '$label',"
    fi
    echo 'Please enter a short, unique, & distinguishing Live directory name here:' > /tmp/prompt
    [ "$PLYMOUTH" ] || list="$list
\`"
    case_block() {
        case "$REPLY" in
            *[[:space:]]* | *[[:cntrl:]]* | '')
                echo "LiveDir '$REPLY' is null, has whitespace, or control characters; Please select another LiveDir name:" > /tmp/prompt
                ;;
            break)
                Die "Forced break from prompt_for_livedir()."
                ;;
            *)
                if [ -d /run/initramfs/ESP/"$REPLY" ]; then
                    echo "LiveDir '$REPLY' already exists; Please select another LiveDir name:" > /tmp/prompt
                else
                    [ "$base_dir" ] && srcdir=$base_dir
                    obj="$REPLY"
                fi
                ;;
        esac
    }

    end_block() {
        [ -b "$ESP" ] && umount /run/initramfs/ESP
        [ "$srcdir" = PROMPT ] && srcdir=LiveOS
        ln -sf "$REPLY" /run/initramfs/ovl_dir
    }
    prompt_for_input
}

# Prompt for new partition size.
prompt_for_size() {
    local - OLDIFS space _warn sz_max
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
    _warn='`
`   Enter a size in GiBytes for the new persistence partition.
`
`   Below is the current partitioning.
`'
    [ "$PLYMOUTH" ] || _list="
$_warn
$space
\`
\`   $sz_max GiB is the upper limit.
"
    echo "Enter a whole number (GiB) for the partition size (max=$sz_max GiB) here: " > /tmp/prompt
    case_block() {
        [ "$REPLY" -gt "$sz_max" ] && echo "
            That's too large..." && REPLY=''
        case "$REPLY" in
            break) obj='break' ;;
            '' | *[!0-9]* | 0[0-9]* | 0*) obj='continue' ;;
        esac
    }
    end_block() {
        obj="$REPLY"
    }
    prompt_for_input
    size="$objSelected"
    return 0
}

# Prompt for a new partition fstype and set rootflags.
prompt_for_fstype() {
    local - i t fslist _warn
    set +x
    set -- btrfs ext4 f2fs xfs
    i=0
    for t; do
        [ -x /usr/sbin/mkfs."$t" ] && {
            fslist="$fslist
$i - $t"
            i=$((i + 1))
        }
    done
    _warn='`
`   Enter the number for the filesystem type of the new partition.'
    list="
$_warn
$fslist
"
    echo 'Enter a number for your fstype here: ' > /tmp/prompt
    case_block() {
        case "$REPLY" in
            '' | *[!0-9]* | 0[0-9]*) obj='continue' ;;
            [0-3]) : ;;
            *) obj='continue' ;;
        esac
    }
    end_block() {
        obj="${list#*"$REPLY" - }"
        obj="${obj%%
*}"
    }
    prompt_for_input
    p_ptfsType="$objSelected"
    set_FS_options "$p_ptfsType"
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
            iso | ciso)
                cfg="$1"
                isofile=$(readlink -f /run/initramfs/isofile)
                ;;
            new_pt_for:*)
                # New overlay partition for an existing live_dir:
                base_dir="${1##*:}"
                cfg=ovl:"${1%:*}"
                # Trigger default ovlpath specification.
                rd_live_overlay=''
                ;;
            esp=*)
                szESP=${1#esp=}
                espStart=1
                ;;
            ea=?*)
                extra_attrs="${*}"
                extra_attrs=${extra_attrs#ea=}
                break
                # ea,extra attribute,s must be the final arguments.
                ;;
            new_pt_for:*)
                # New overlay partition for an existing ovl_dir:
                base_dir="${1##*:}"
                cfg=ovl:"${1%:*}"
                # Trigger default ovlpath specification.
                rd_overlay=''
                ;;
            PROMPTDK | PROMPTPT)
                prompt_for_device "${1#PROMPT}"
                ;;
            PROMPTDR)
                prompt_for_path "$1"
                ;;
            PROMPTSZ)
                # Assigns sizeGiB.
                prompt_for_size "$1"
                ;;
            PROMPTFS)
                # Assigns fsType and rootflags.
                prompt_for_fstype
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
    [ "$p_pt" ] && ! [ -b "$p_pt" ] \
        && Die "The specified persistence partition, $p_pt, is not recognized."
    if [ "$p_pt" ] && ! [ "$removePt" ]; then
        info "Skipping overlay creation: a persistence partition already exists."
        rd_overlay="$p_pt"
        ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.overlay=$p_pt"
        return 0
    elif [ ! "$rd_overlay" ]; then
        info "Skipping overlay creation: kernel command line parameter 'rd.overlay' is not set."
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
        # dd'd .iso size
        sz=$((freeSpaceStart + 32768))
    }
    byteMax=$((szDisk - 268435456))

    # Make optimalIO alignment at least 4 MiB.
    #   See https://www.gnu.org/software/parted/manual/parted.html#FOOT2 .
    [ "${optimalIO:-0}" -lt 4194304 ] && optimalIO=4194304

    # Set optimalIO address for partition start - $1, variable - $2
    optimize() {
        eval "$2"=$((($1 + optimalIO - 1) / optimalIO * optimalIO))
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

    case "$cfg" in
        iso)
            [ "$mklabel" ] && {
                # dd'd .iso -> loaded .iso on reformatted disc.
                mkdir -p /run/initramfs/iso
                isofile=/run/initramfs/iso/${label}.iso
                src="$diskDevice" dst="$isofile" sz="$sz" dd_copy
                ln -s "$isofile" /run/initramfs/isofile
            }
            ;;
    esac

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
        if [ "$mklabel" ]; then
            espNbr=1
            unset -v 'removePtNbr'
            wipefs --lock -af${QUIET:+q} "$diskDevice"
        else
            espCmd="rm ${espNbr:=1}"
        fi
        espCmd="${espCmd:+rm "$espNbr"} --align optimal mkpart ESP fat32 ${espStart}B ${espEnd:=$((partitionStart - 1))}B \
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
    p_ptCmd="--align optimal mkpart ${live_dir}.. ${partitionStart}B ${partitionEnd}B"

    run_parted "$diskDevice" --fix ${removePtNbr:+rm $removePtNbr} \
        "${newptCmd:=--align optimal mkpart LiveOS_persist "${partitionStart}B" "${partitionEnd}B"}"

    newptCmd="$p_ptCmd"
    # LiveOS persistence partition type
    newptType=ccea7cb3-70ba-4c31-8455-b906e46a00e2

    # shellcheck disable=SC2086
    run_parted "${diskDevice}" --fix ${mklabel:+mklabel ${mklabel:=gpt}} \
        ${removePtNbr:+rm "$removePtNbr"} \
        ${espCmd:+$espCmd} \
        ${newptCmd}
    : "${cfg:=ovl}"

    [ "$espCmd" ] && {
        udevadm trigger --name-match "$ESP" --action add --settle > /dev/kmsg 2>&1
        mkfs_config fat ESP $((partitionStart - espStart))
        create_Filesystem fat "$ESP"
    }

    # Set new partition type with command - $@
    set_pt_type() {
        get_partitionTable "$diskDevice"
        get_newptNbr "$@"
        run_parted "$diskDevice" type "$newptNbr" "$newptType" \
            set "$newptNbr" no_automount on
    }
    # shellcheck disable=SC2086
    set_pt_type $newptCmd

    [ "$p_Partition" ] || {
        p_Partition=$(aptPartitionName "$diskDevice" "$newptNbr")

        udevadm trigger --name-match "$p_Partition" --action add --settle > /dev/kmsg 2>&1
        ln -sf "$p_Partition" /run/initramfs/p_pt

        [ "$p_ptFlags" ] || set_FS_opts_w "${fsType:-ext4}" p_ptFlags
        mkfs_config "${p_ptfsType:=ext4}" LiveOS_persist $((partitionEnd - partitionStart + 1)) "${extra_attrs}"
        wipefs --lock -af${QUIET:+q} "$p_Partition"
        create_Filesystem "$p_ptfsType" "$p_Partition"
    }
}

install_Image() {
    local src dst loopdev
    case "$cfg" in
        ciso)
            mkdir -p "$mntDir"/isos
            isofile="$mntDir/isos/${isofile##*/}"
            src=/run/initramfs/isofile dst="$isofile" msg='to disk...' dd_copy
            [ -h /run/initramfs/isoloop ] && {
                losetup -d /run/initramfs/isoloop
                umount /run/initramfs/isoscan > /dev/null 2>&1
            }
            ln -sf "$p_pt" /run/initramfs/isoscandev
            [ "${DRACUT_SYSTEMD-}" ] && mount --make-rprivate /run
            loopdev=$(losetup -f)
            losetup -rP "$loopdev" "$isofile"
            ln -sf "$loopdev" /run/initramfs/isoloop
            livedev="${loopdev}p1"
            ln -sf "$livedev" /run/initramfs/livedev
            srcdir=LiveOS
            ln -sf "$isofile" /run/initramfs/isofile
            ;;
    esac
    [ -d /run/initramfs/iso ] && {
        # Recover tmpfs storage space.
        rm -rf -- /run/initramfs/iso
    }
}

