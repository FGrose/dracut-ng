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
    local - _ISS dev_serials _dev
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
    # Exclude major 252, zram
    dev_serials="$(lsblk -e 252 -dnro PATH,SERIAL 2> /dev/null)
"
    _dev=${dev_serials%% "$_ISS"
*}
    _dev="${_dev##*
}"
    [ "$_dev" ] && {
        echo "$_dev"
        return 0
    }
    return 1
}

# Trigger a disk or partition, $1, having property [LABEL=|UUID=|PARTLABEL=|PARTUUID=|serial=<SERIAL_SHORT>/serial/]*
#   for action, $2, [add|remove|change|move|online|offline|bind|unbind] - default: add
label_uuid_udevadm_trigger() {
    local _dev _property
    _dev="${1#block:}"
    case "$_dev" in
        LABEL=* | UUID=*)
            _property=ID_FS_${_dev}
            ;;
        PARTLABEL=*)
            _property=ID_PART_ENTRY_NAME=${_dev#PARTLABEL=}
            ;;
        PARTUUID=*)
            _property=ID_PART_ENTRY_${_dev#PART}
            ;;
        serial=*/serial/*)
            _dev="${_dev#serial}"
            _property=ID_SERIAL_SHORT${_dev%/serial/*}
            udevadm trigger --subsystem-match=block --action="${2:-add}" ${_property:+--property-match=$_property} --settle
            _dev=${_dev#*/serial/}
            [ "$_dev" ] && label_uuid_udevadm_trigger "$_dev"
            ;;
    esac
    udevadm trigger --subsystem-match=block --action="${2:-add}" ${_property:+--property-match=$_property} --settle
}


# get a systemd-compatible unit name from a path
# (mimics unit_name_from_path_instance())
dev_unit_name() {
    local dev="$1"

    if command -v systemd-escape > /dev/null; then
        case $dev in
            */*) systemd-escape -p -- "$dev" ;;
            *) systemd-escape -- "$dev" ;;
        esac
        return $?
    fi

    if [ "$dev" = "/" ] || [ -z "$dev" ]; then
        printf -- "-"
        return 0
    fi

    dev="${1%%/}"
    dev="${dev##/}"
    # shellcheck disable=SC1003
    dev="$(str_replace "$dev" '\' '\x5c')"
    dev="$(str_replace "$dev" '-' '\x2d')"
    if [ "${dev##.}" != "$dev" ]; then
        dev="\x2e${dev##.}"
    fi
    dev="$(str_replace "$dev" '/' '-')"

    printf -- "%s" "$dev"
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
    if ! [ -L "${PREFIX-}/etc/systemd/system/initrd.target.wants/${_name}.device" ]; then
        [ -d "${PREFIX-}"/etc/systemd/system/initrd.target.wants ] || mkdir -p "${PREFIX-}"/etc/systemd/system/initrd.target.wants
        ln -s ../"${_name}".device "${PREFIX-}/etc/systemd/system/initrd.target.wants/${_name}.device"
        type mark_hostonly > /dev/null 2>&1 && mark_hostonly /etc/systemd/system/initrd.target.wants/"${_name}".device
        _needreload=1
    fi

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
    local _noreload

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
