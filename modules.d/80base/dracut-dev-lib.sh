#!/bin/sh

# replaces all occurrences of 'search' in 'str' with 'replacement'
#
# str_replace str search replacement
#
# example:
# str_replace '  one two  three  ' ' ' '_'
str_replace() {
    local in="$1"
    local s="$2"
    local r="$3"
    local out=''

    while [ "${in##*"$s"*}" != "$in" ]; do
        chop="${in%%"$s"*}"
        out="${out}${chop}$r"
        in="${in#*"$s"}"
    done
    printf -- '%s' "${out}${in}"
}

# Return an appropriate name for device $1 partition [$2]. Device names
# that end with a digit must have a 'p' prepended to the partition number.
aptPartitionName() {
    local - dev="$1"
    set +x
    # Default to partition 1 if missing, 0, or negative.
    local ptNbr="${2:-1}"
    [ "$ptNbr" -lt 1 ] && ptNbr=1

    case "${dev}~" in
        # If an existing dm device, find and use its name.
        *dm-[0-9]~)
            local ppath=/devices/virtual/block/"${dev##*/}"
            dev=/dev/mapper/$(cat /sys"$ppath"/dm/name)
            ;;
    esac
    case "${dev}~" in
        *[0-9]~)
            printf '%s' "${dev}p$ptNbr"
            ;;
        *)
            printf '%s' "${dev}$ptNbr"
            ;;
    esac
}

# mask any commas in ID_SERIAL_SHORT so they don't trigger field separations.
# $1 - *[serial=]ID_SERIAL_SHORT[/serial/]*
# commas before serial= and after /serial/ are untouched.
# (Both commas and semicolons are possible, but rarely seen characters; seeing
#  both at once should be even rarer.)
maskComma_inSerial() {
    local - ISS _ISS
    set +x
    ISS=${1#*serial=}
    ISS=${ISS%/serial/*}
    if strstr "$ISS" ,; then
        local b a _ISS
        b=${1%"${ISS}"*}
        a=${1#*"$ISS"}
        _ISS=$(
            sed 's/,/;/g' << E
$ISS
E
        )
        echo "$b$_ISS$a"
    else
        echo "$1"
    fi
}

# Find the disc device with a particular serial number.
#   $1 - device serial number with commas masked to semicolons.
#   False if not found.
ID_SERIAL_SHORT_to_disc() {
    local - _ISS dev_id s_path d_node
    set +x
    if strstr "$1" \;; then
        # Unmask commas.
        _ISS=$(
            sed 's/;/,/g' << E
$1
E
        )
    else
        _ISS=$1
    fi
    for s_path in /sys/class/block/*; do
        [ -d "$s_path" ] || continue
        read -r dev_id < "$s_path"/dev
        case "${dev_id%:*}" in
            # Exclude loop, cdrom, & zram
            7 | 11 | 25[129]) continue ;;
        esac
        [ -f "$s_path"/partition ] && continue
        d_node=/dev/"${s_path##*/}"
        [ -e "$d_node" ] || continue
        ser=''
        if [ -f "$s_path"/device/serial ]; then
            read -r ser < "$s_path"/device/serial
        elif [ -f "$s_path"/device/device/serial ]; then
            read -r ser < "$s_path"/device/device/serial
        elif [ -f "$s_path"/uevent ]; then
            while read -r line; do
                case "$line" in ID_SERIAL_SHORT=*) ser="${line#*=}" ;; esac
            done < "$s_path"/uevent
        fi
        [ "$ser" ] || ser=$(udevadm info -q property --value --property=ID_SERIAL_SHORT "$d_node")
        [ "$ser" = "$_ISS" ] && {
            echo "$d_node"
            return 0
        }
    done
    return 1
}

# Trigger a disk or partition having property spec
#  $1 - {LABEL=|UUID=|PARTLABEL=|PARTUUID=|serial=<SERIAL_SHORT>/serial/[spec]}
#  for action $2 - [add|remove|change|move|online|offline|bind|unbind] default: add
label_uuid_udevadm_trigger() {
    local _dev="${1#block:}" _act="${2:-add}" _prop=''
    case "$_dev" in
        serial=*/serial/*)
            _dev="${_dev#serial}"
            _prop=ID_SERIAL_SHORT"${_dev%/serial/*}"
            udevadm trigger --subsystem-match=block --action="$_act" --property-match="$_prop" --settle
            _dev="${_dev#*/serial/}"
            # _dev may have a partition specified after /serial/
            [ "$_dev" ] && label_uuid_udevadm_trigger "$_dev" "$_act" --settle
            return 0
            ;;
        LABEL=* | UUID=*)
            _prop=ID_FS_"${_dev}"
            ;;
        PARTLABEL=*)
            _prop=ID_PART_ENTRY_NAME="${_dev#PARTLABEL=}"
            ;;
        PARTUUID=*)
            _prop=ID_PART_ENTRY_"${_dev#PART}"
            ;;
    esac
    udevadm trigger --subsystem-match=block --action="$_act" ${_prop:+--property-match="$_prop"} --settle
}

# set_systemd_timeout_for_dev [-n] <dev> [<timeout>]
# Set 'rd.timeout' as the systemd timeout for <dev>
set_systemd_timeout_for_dev() {
    local _name
    local _needreload
    local _noreload
    local _timeout

    [ -z "${DRACUT_SYSTEMD-}" ] && return 0

    if [ "$1" = "-n" ]; then
        _noreload=1
        shift
    fi

    if [ -n "$2" ]; then
        _timeout="$2"
    else
        _timeout=$(getarg rd.timeout)
    fi

    _timeout=${_timeout:-infinity}

    _name=$(dev_unit_name "$1")

    if ! [ -f "${PREFIX-}/etc/systemd/system/${_name}.device.d/timeout.conf" ]; then
        mkdir -p "${PREFIX-}/etc/systemd/system/${_name}.device.d"
        {
            echo "[Unit]"
            echo "JobTimeoutSec=$_timeout"
            echo "JobRunningTimeoutSec=$_timeout"
        } > "${PREFIX-}/etc/systemd/system/${_name}.device.d/timeout.conf"
        type mark_hostonly > /dev/null 2>&1 && mark_hostonly /etc/systemd/system/"${_name}".device.d/timeout.conf
        _needreload=1
    fi

    if [ -z "${PREFIX-}" ] && [ "$_needreload" = 1 ] && [ -z "$_noreload" ]; then
        /sbin/initqueue --onetime --unique --name daemon-reload systemctl daemon-reload
    fi
}

# wait_for_dev <dev> [<timeout>]
#
# Installs a initqueue-finished script,
# which will cause the main loop only to exit,
# if the device <dev> is recognized by the system.
wait_for_dev() {
    local _name
    local _needreload
    local _noreload
    local _unit

    if [ "$1" = "-n" ]; then
        _noreload=-n
        shift
    fi

    _name="$(str_replace "$1" '/' '\x2f')"

    type mark_hostonly > /dev/null 2>&1 && mark_hostonly "$hookdir/initqueue/finished/devexists-${_name}.sh"

    [ -e "${PREFIX-}$hookdir/initqueue/finished/devexists-${_name}.sh" ] && return 0

    printf '[ -e "%s" ]\n' "$1" \
        >> "${PREFIX-}$hookdir/initqueue/finished/devexists-${_name}.sh"
    {
        printf '[ -e "%s" ] || ' "$1"
        printf 'warn "\"%s\" does not exist"\n' "$1"
    } >> "${PREFIX-}$hookdir/emergency/80-${_name}.sh"

    [ -n "${DRACUT_SYSTEMD-}" ] || return 0
    _unit="$(dev_unit_name "$1").device"

    if ! [ -L "${PREFIX-}/etc/systemd/system/initrd.target.wants/${_unit}" ]; then
        [ -d "${PREFIX-}"/etc/systemd/system/initrd.target.wants ] || mkdir -p "${PREFIX-}"/etc/systemd/system/initrd.target.wants
        ln -s ../"${_unit}" "${PREFIX-}/etc/systemd/system/initrd.target.wants/${_unit}"
        type mark_hostonly > /dev/null 2>&1 && mark_hostonly /etc/systemd/system/initrd.target.wants/"${_unit}"
        _needreload=1
    fi

    if [ -z "${PREFIX-}" ] && [ "$_needreload" = 1 ] && [ -z "$_noreload" ]; then
        /sbin/initqueue --onetime --unique --name daemon-reload systemctl daemon-reload
    fi

    set_systemd_timeout_for_dev $_noreload "$@"
}

cancel_wait_for_dev() {
    local _name
    _name="$(str_replace "$1" '/' '\x2f')"
    rm -f -- "$hookdir/initqueue/finished/devexists-${_name}.sh"
    rm -f -- "$hookdir/emergency/80-${_name}.sh"
    if [ -n "${DRACUT_SYSTEMD-}" ]; then
        _name=$(dev_unit_name "$1")
        rm -f -- "${PREFIX-}/etc/systemd/system/initrd.target.wants/${_name}.device"
        rm -f -- "${PREFIX-}/etc/systemd/system/${_name}.device.d/timeout.conf"
        /sbin/initqueue --onetime --unique --name daemon-reload systemctl daemon-reload
    fi
}
