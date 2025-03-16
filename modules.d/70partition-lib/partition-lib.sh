#!/bin/sh
# partition-lib.sh: utilities for partition editing
command -v set_FS_options > /dev/null || . /lib/distribution-live-lib.sh

plymouth --ping > /dev/null 2>&1 && {
    export PLYMOUTH=PLYMOUTH
    . /lib/plymouth-lib.sh
}

run_parted() {
    LC_ALL=C flock "$1" parted --script "$@"
}

# call in this fashion:
#   src=<source image file or block device>
#   dst=<destination path>
#     [var=<name of variable holding the destination path>]
#     [sz=<image size in bytes>]
#     [msg=<message text for copy to persistent media>] dd_copy
dd_copy() {
    local src dst var sz msg ddir
    ddir=${dst%/*}
    [ "$ddir" != /dev ] && [ "$(findmnt -nro FSTYPE -T "$ddir")" = tmpfs ] && {
        src=$(readlink -f "$src")
        [ "$sz" ] || sz=$(blkid --probe --match-tag FSSIZE --output value --usages filesystem "$src")
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
    ln -sf "$diskDevice" /run/initramfs/diskdev
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
            ln -sf "$diskDevice" /run/initramfs/diskdev
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

# Prompt for Live directory name
prompt_for_livedir() {
    local - message_list d PROMPT
    set +x
    get_ESP "$diskDevice"
    # Some hardware devices need more time to respond in very early boot.
    sleep 0.1
    if mount -n -t vfat -m -o check=s "$ESP" /run/initramfs/ESP; then
        message_list='`
`  Installed LiveOS directories:'
        for d in /run/initramfs/ESP/*/images; do
            d=${d#*ESP/}
            d=${d%/images}
            [ "$d" = "*" ] || message_list="$message_list
    \`  $d"
        done
        for d in /run/initramfs/ESP/*/boot; do
            d=${d#*ESP/}
            d=${d%/boot}
            [ "$d" = "*" ] || message_list="$message_list
    \`  $d"
        done
    else
        message_list='To recognize your image installation,'
    fi
    if [ "$base_dir" ]; then
        message_list="$message_list
\`  For a new overlay for the system image '$base_dir',"
    else
        message_list="$message_list
\`  For the image labeled '$label',"
    fi
    PROMPT="Please enter a short, unique, & distinguishing Live directory name here: "

    [ "$PLYMOUTH" ] || message_list="$message_list
\`
"
    {
        flock -s 9
        while :; do
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "$message_list
Press <Escape> to toggle to/from the message display."
                live_dir=$(plymouth ask-question --prompt="$PROMPT")
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${message_list%
*}" > /dev/kmsg
                live_dir=$(systemd-ask-password --echo=yes --timeout=0 "$PROMPT")
            else
                PROMPT="${message_list}
$PROMPT"
                read -p "$PROMPT" -r live_dir
            fi
            case "$live_dir" in
                *[[:space:]]* | *[[:cntrl:]]* | '')
                    PROMPT="LiveDir '$live_dir' is null, has whitespace, or control characters; Please select another LiveDir name: "
                    ;;
                break)
                    Die "Forced break from prompt_for_livedir()."
                    ;;
                *)
                    if [ -d /run/initramfs/ESP/"$live_dir" ]; then
                        PROMPT="LiveDir '$live_dir' already exists; Please select another LiveDir name: "
                    else
                        [ "$base_dir" ] && srcdir=$base_dir
                        break
                    fi
                    ;;
            esac
        done
    } 9> /.console_lock
    [ -b "$ESP" ] && umount /run/initramfs/ESP
    [ "$srcdir" = PROMPT ] && srcdir=LiveOS
    printf '%s' "$live_dir" > /run/initramfs/live_dir
    printf '%s' "$live_dir"
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

# Prompt for a new partition fstype and set rootflags.
prompt_for_fstype() {
    local - i t fslist warn
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
    fslist="$fslist
"
    warn='`
`   Enter the number for the filesystem type of the new partition.'
    _list="
$warn
$fslist
Enter a number here: 
"
    {
        flock -s 9
        while :; do
            if [ "$PLYMOUTH" ]; then
                IFS='
' plym_write "$fslist
Press <Escape> to toggle to/from your fstype selection display."
                REPLY=$(plymouth ask-question --prompt='Enter a number for your fstype here')
            elif [ "${DRACUT_SYSTEMD-}" ]; then
                echo "${_list%
*}" > /dev/kmsg
                REPLY=$(systemd-ask-password --echo=yes --timeout=0 'Choose your filesystem type (btrfs=0 ext4=1 f2fs=2 xfs=3) by #: ')
            else
                read -p "$_list" -r
            fi
            case "$REPLY" in
                '') continue ;;
                *[!0-9]* | 0[0-9]*) continue ;;
                [0-3]) break ;;
            esac
        done
    } 9> /.console_lock
    fsType="${_list#*"$REPLY" - }"
    fsType="${fsType%%
*}"
    echo "$fsType"
    set_FS_options "$fsType"
    return 0
}

parse_cfgArgs() {
    local - ISS ptSpec
    if strstr "$@" serial=; then
        # shellcheck disable=SC2046
        set -- $(maskComma_inSerial "$@")
    else
        # shellcheck disable=SC2068
        set -- $@ # rd_live_overlay or rd_live_image
    fi
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
            mklabel)
                mklabel=gpt
                ESP=$(aptPartitionName "$diskDevice" 1)
                ln -sf "$ESP" /run/initramfs/espdev
                espStart=1
                ;;
            ropt)
                cfg="$1"
                ;;
            auto)
                espStart=1
                cfg=ovl
                ;;
            ciso)
                cfg="$1"
                isofile=$(readlink -f /run/initramfs/isofile)
                ;;
            new:* | new+p_pt:*)
                # New overlay based on existing live_dir:
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
            PROMPTDK | PROMPTPT)
                prompt_for_device "${1#PROMPT}"
                ;;
            PROMPTSZ)
                # Assigns sizeGiB.
                prompt_for_size "$1"
                ;;
            PROMPTFS)
                # Assigns fsType and filesystem options.
                prompt_for_fstype
                ;;
            *[!0-9]* | 0*)
                # Anything but a positive integer:
                p_Partition="$(readlink -f "$(label_uuid_to_dev "${1%%:*}")" 2> /dev/kmsg)"
                get_diskDevice "$p_Partition"
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
    case "$cfg" in
        ropt) ;;
        *) [ "$p_Partition" ] && return 0 ;;
    esac
    local parentDisk removePtNbr freeSpaceStart freeSpaceEnd byteMax espCmd \
        roptCmd p_ptCmd newptCmd roptStart espEnd newptType sz
    #[ "$p_Partition" ] && ! [ -b "$p_Partition" ] \
    #    && Die "The specified persistence partition, $p_Partition, is not recognized."
    #[ "$p_Partition" ] && ! [ "$removePt" ] && {
    #    info "Skipping overlay creation: a persistence partition already exists."
    #    rd_live_overlay="$p_Partition"
    #    ETC_KERNEL_CMDLINE="$ETC_KERNEL_CMDLINE rd.live.overlay=$p_Partition rd.live.overlay.overlayfs"
    #    return 0
    #}
    freeSpaceEnd=$((szDisk - 1048576))
    [ "$removePt" ] && {
        [ "${removePt#"$diskDevice"}" = "$removePt" ] && {
            # removePt NOT on diskDevice.
            # shellcheck disable=SC2046
            set -- $(lsblk -nrpo PKNAME,OPT-IO "$removePt")
            diskDevice="$1"
            ln -sf "$diskDevice" /run/initramfs/diskdev
            optimalIO="$2"
            get_partitionTable "$diskDevice"
        }
        removePtNbr="${removePt#"$diskDevice"}"
        removePtNbr="${removePt#"$parentDisk"}"
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
    # Make optimalIO alignment at least 4 MiB.
    #   See https://www.gnu.org/software/parted/manual/parted.html#FOOT2 .
    [ "${optimalIO:-0}" -lt 4194304 ] && optimalIO=4194304

    # Set optimalIO address for partition start - $1, variable - $2
    optimize() {
        [ $(($1 % optimalIO)) -gt 0 ] \
            && eval "$2"=$((($1 / optimalIO + 1) * optimalIO))
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
            removePt=$(aptPartitionName "$diskDevice" "$removePtNbr")
            freeSpaceStart=${2%B}
            espStart=1
            ;;
        Appended2)
            espStart=1
            ;;
    esac
    [ "$removePt" ] || {
        freeSpaceStart=$((${3%B} + 1))
        # dd'd .iso size
        sz=$((freeSpaceStart + 32768))
    }
    byteMax=$((szDisk - 268435456))

    [ "$ESP" ] || get_ESP "$diskDevice"
    IFS=:
    # shellcheck disable=SC2086
    set -- ${espRow:=1:${optimalIO}B:3:4:5:6}
    IFS="$OLDIFS"

    case "$cfg" in
        iso | ropt)
            [ "$mklabel" ] && {
                # dd'd .iso -> loaded .iso or ropt on reformatted disc.
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

    case "$cfg" in
        ropt)
            if [ -d /run/initramfs/iso ]; then
                loopdev=$(losetup -P -r -f --show /run/initramfs/isofile)
            else
                loopdev=$(readlink -f /run/initramfs/isoloop)
            fi
            mount -n -m -r -t iso9660 "$loopdev"p1 /run/initramfs/live
            sz=$(blkid --probe --match-tag FSSIZE --output value --usages filesystem -- /run/initramfs/live/LiveOS/"$squash_image")

            umount -d /run/initramfs/live
            losetup -d "$loopdev"
            roptStart=$partitionStart
            partitionStart=$((roptStart + sz + 1))
            optimize "$partitionStart" partitionStart
            roptCmd="--align optimal mkpart $live_dir ${roptStart}B $((partitionStart - 1))B"
            espEnd=$((roptStart - 1))
            ;;
    esac

    if [ "$partitionStart" -gt "$byteMax" ]; then
        # Allow at least 256 MiB for persistence partition.
        warn "Skipping partition creation: less than 256 MiB of space is available."
        return 1
    fi
    sizeGiB=${sizeGiB:+$((sizeGiB << 30))}
    partitionEnd="$((partitionStart + ${sizeGiB:-$szDisk} - 512))"
    [ "$partitionEnd" -gt "$freeSpaceEnd" ] && partitionEnd="$freeSpaceEnd"
    p_ptCmd="--align optimal mkpart ${live_dir}.. ${partitionStart}B ${partitionEnd}B"

    [ "$removePtNbr" ] && wipefs --lock -af${QUIET:+q} "$removePt"
    [ "$espCmd" ] && wipefs --lock -af${QUIET:+q} "$ESP"

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

    [ "$espCmd" ] && {
        udevadm trigger --name-match "$ESP" --action add --settle > /dev/kmsg 2>&1
        mkfs_config fat ESP $((espEnd - espStart))
        create_Filesystem fat "$ESP"
    }

    # Set new partition type for command - $@
    set_pt_type() {
        get_partitionTable "$diskDevice"
        get_newptNbr "$@"
        run_parted "$diskDevice" type "$newptNbr" "$newptType" \
            set "$newptNbr" no_automount on
    }
    # shellcheck disable=SC2086
    set_pt_type $newptCmd

    [ "$roptStart" ] && {
        ro_Partition=$(aptPartitionName "$diskDevice" "$newptNbr")
        [ "$p_Partition" ] || {
            newptType=ccea7cb3-70ba-4c31-8455-b906e46a00e2
            # shellcheck disable=SC2086
            run_parted "$diskDevice" \
                $p_ptCmd
            # shellcheck disable=SC2086
            set_pt_type $p_ptCmd
        }
    }

    [ "$p_Partition" ] || {
        p_Partition=$(aptPartitionName "$diskDevice" "$newptNbr")

        udevadm trigger --name-match "$p_Partition" --action add --settle > /dev/kmsg 2>&1
        ln -sf "$p_Partition" /run/initramfs/p_pt

        [ "$p_ptFlags" ] || set_FS_options "${fsType:-ext4}"
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
            ln -sf "$p_Partition" /run/initramfs/isoscandev
            [ "${DRACUT_SYSTEMD-}" ] && mount --make-rprivate /run
            loopdev=$(losetup -P -r -f --show "$isofile")
            ln -sf "$loopdev" /run/initramfs/isoloop
            livedev="${loopdev}p1"
            ln -sf "$livedev" /run/initramfs/livedev
            srcdir=LiveOS
            ln -sf "$isofile" /run/initramfs/isofile
            ;;
        ropt)
            umount /run/initramfs/rorootfs
            src=$ROROOTFS dst=$ro_Partition msg='to disk...' dd_copy
            losetup -d "$ROROOTFS"
            ROROOTFS=$ro_Partition

            if [ "$base_dir" ]; then
                roPARTUUID=$(readlink /run/initramfs/live/"${base_dir}"/rorootfs.img)
                roPARTUUID=${roPARTUUID##*/}
            else
                roPARTUUID=$(lsblk -nro PARTUUID "$ro_Partition")
            fi
            printf '%s' "$roPARTUUID" > /run/initramfs/live_partuuid
            # Set ovlpath.
            ovlpath="/${live_dir}/overlay-${label}-$roPARTUUID"
            uuid=$roPARTUUID
            ;;
        ropt_2)
            cd /run/initramfs/live"${base_dir:+/$base_dir}" || Die "Unable to change directory to /run/initramfs/live${base_dir:+/$base_dir}"
            # Copy source image minus LiveOS directory and any overlay.
            find . -type f \! -path ./LiveOS -prune \! -path ./overlay-\* -prune \
                \! -path ./ovlwork -prune \! -name squashfs.img -prune \! -name rorootfs.img -prune | cpio -p -dum --quiet "$mntDir/$live_dir"/.
            cd - || Die "Problem changing directory from /run/initramfs/live${base_dir:+/$base_dir}"
            umount -d /run/initramfs/live
            losetup -d /run/initramfs/isoloop
            umount /run/initramfs/isoscan
            rmdir /run/initramfs/isoscan
            # Establish link to rorootfs base partition.
            ln -sf /dev/disk/by-partuuid/"$roPARTUUID" "${mntDir}/${live_dir}"/rorootfs.img
            mount --bind "$mntDir/$live_dir" /run/initramfs/live
            ln -sf "$p_Partition" /run/initramfs/livedev
            rm -- /run/initramfs/isoloop /run/initramfs/isofile /run/initramfs/isoscandev
            ;;
    esac
    [ -d /run/initramfs/iso ] && {
        # Recover tmpfs storage space.
        rm -rf -- /run/initramfs/iso
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
            ln -sf "$p_Partition" /run/initramfs/isoscandev
            [ "${DRACUT_SYSTEMD-}" ] && mount --make-rprivate /run
            loopdev=$(losetup -P -r -f --show "$isofile")
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
