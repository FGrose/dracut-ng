#!/bin/sh
# core functions for minimal sourcing, such as for early boot generators.

# returns OK if $1 contains literal string $2 (and isn't empty)
strstr() {
    [ "${1##*"$2"*}" != "$1" ]
}

getcmdline() {
    local _line
    local _i
    local CMDLINE_ETC_D=''
    local CMDLINE_ETC=''
    local CMDLINE_PROC=''
    local CMDLINE_RUN=''
    local CMDLINE_ETC_KERNEL=''
    unset _line

    if [ -e /etc/cmdline ]; then
        while read -r _line || [ -n "$_line" ]; do
            CMDLINE_ETC="$CMDLINE_ETC $_line"
        done < /etc/cmdline
    fi
    for _i in /etc/cmdline.d/*.conf; do
        [ -e "$_i" ] || continue
        while read -r _line || [ -n "$_line" ]; do
            CMDLINE_ETC_D="$CMDLINE_ETC_D $_line"
        done < "$_i"
    done
    if [ -e /proc/cmdline ]; then
        while read -r _line || [ -n "$_line" ]; do
            CMDLINE_PROC="$CMDLINE_PROC $_line"
        done < /proc/cmdline
    fi
    for _i in /run/initramfs/cmdline.d/*.conf; do
        [ -e "$_i" ] || continue
        while read -r _line || [ -n "$_line" ]; do
            CMDLINE_RUN="$CMDLINE_RUN $_line"
        done < "$_i"
    done
    # Ordered last for boot-time precedence.
    if [ -e /etc/kernel/cmdline ]; then
        while read -r _line || [ -n "$_line" ]; do
            CMDLINE_ETC_KERNEL="$CMDLINE_ETC_KERNEL $_line"
        done < /etc/kernel/cmdline
    fi
    CMDLINE="$CMDLINE_ETC_D $CMDLINE_ETC $CMDLINE_PROC $CMDLINE_RUN $CMDLINE_ETC_KERNEL"
    printf "%s" "$CMDLINE"
}

# getarg <KEY>[=[<VALUE>]] [-d [-{y|n}] <alt_KEY>[=[<VALUE>]] ...]
# With <KEY>[=], print the <VALUE> of the final instance of <KEY>=<VALUE> in
# the kernel command line and return success.
# When a =<VALUE> argument is provided, return success or failure only, but
# note that a '=0' argument will return success, so use getargbool() instead,
# so that, for example, getargbool 0 rd.info will return failure when rd.info=0
# is on the command line (eventhough getargbool 0 rd.info=0 will return success).
# -d signals that <alt_KEY> is deprecated in place of <KEY>;
# -{y|n} signals that success|failure should be returned on =<VALUE> or <KEY> match,
# and -n will also suggest using '<KEY>=0' be used if <alt_KEY> was used.
getarg() {
    debug_off
    local _deprecated='' _newoption=''
    CMDLINE=$(getcmdline)
    export CMDLINE
    while [ $# -gt 0 ]; do
        case $1 in
            -d)
                _deprecated=1
                shift
                ;;
            -y)
                if dracut-getarg "$2" > /dev/null; then
                    if [ "$_deprecated" = "1" ]; then
                        if [ -n "$_newoption" ]; then
                            warn "Kernel command line option '$2' is deprecated, use '$_newoption' instead."
                        else
                            warn "Option '$2' is deprecated."
                        fi
                    fi
                    echo 1
                    debug_on
                    return 0
                fi
                _deprecated=0
                shift 2
                ;;
            -n)
                if dracut-getarg "$2" > /dev/null; then
                    echo 0
                    if [ "$_deprecated" = "1" ]; then
                        if [ -n "$_newoption" ]; then
                            warn "Kernel command line option '$2' is deprecated, use '$_newoption=0' instead."
                        else
                            warn "Option '$2' is deprecated."
                        fi
                    fi
                    debug_on
                    return 1
                fi
                _deprecated=0
                shift 2
                ;;
            *)
                if [ -z "$_newoption" ]; then
                    _newoption="$1"
                fi
                if dracut-getarg "$1"; then
                    if [ "$_deprecated" = "1" ]; then
                        if [ -n "$_newoption" ]; then
                            warn "Kernel command line option '$1' is deprecated, use '$_newoption' instead."
                        else
                            warn "Option '$1' is deprecated."
                        fi
                    fi
                    debug_on
                    return 0
                fi
                _deprecated=0
                shift
                ;;
        esac
    done
    debug_on
    return 1
}

# getargbool <defaultval> <KEY>[=[<VALUE>]] [-d [-{y|n}] <alt_KEY>[=[<VALUE>]] ...]
# getargbool <defaultval> <args...>
# False if "getarg <args...>" returns "0", "no", or "off".
# True if getarg returns any other non-empty string.
# If not found, assumes <defaultval> - usually 0 for false, 1 for true.
# example: `getargbool 0 rd.info`
#  return  command line value
#    true: rd.info, rd.info=1, rd.info=xxx
#   false: rd.info=0, rd.info=off, rd.info not present (default val is 0),
#          but `getargbool [0|1] rd.info=0` returns true.
getargbool() {
    local _b
    unset _b
    local _default
    _default="$1"
    shift
    _b=$(getarg "$@") || _b=${_b:-"$_default"}
    if [ -n "$_b" ]; then
        [ "$_b" = "0" ] && return 1
        [ "$_b" = "no" ] && return 1
        [ "$_b" = "off" ] && return 1
    fi
    return 0
}

# Return a disk device or partition specification from various common input selectors.
label_uuid_to_dev() {
    local _dev ISS diskDevice ptSpec
    _dev="${1#block:}"
    case "$_dev" in
        LABEL=*)
            echo "/dev/disk/by-label/$(echo "${_dev#LABEL=}" | sed 's,/,\\x2f,g;s, ,\\x20,g')"
            ;;
        PARTLABEL=*)
            echo "/dev/disk/by-partlabel/$(echo "${_dev#PARTLABEL=}" | sed 's,/,\\x2f,g;s, ,\\x20,g')"
            ;;
        UUID=*)
            echo "/dev/disk/by-uuid/${_dev#UUID=}"
            ;;
        PARTUUID=*)
            echo "/dev/disk/by-partuuid/${_dev#PARTUUID=}"
            ;;
        serial=*/serial/*)
            ISS=${_dev%%/serial/*}
            diskDevice=$(ID_SERIAL_SHORT_to_disc "${ISS#serial=}")
            ptSpec=${_dev#*/serial/}
            [ "$ptSpec" ] && {
                case "$ptSpec" in
                    *[!0-9]* | 0*)
                        # Anything but a positive integer:
                        label_uuid_to_dev "$ptSpec"
                        ;;
                    *)
                        aptPartitionName "$diskDevice" "$ptSpec"
                        ;;
                esac
            }
            ;;
        *)
            echo "$_dev"
            ;;
    esac
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

# parameter: kernel_module [filesystem_name]
# returns OK if kernel_module is loaded
# modprobe fails if /lib/modules is not available (--no-kernel use case)
load_fstype() {
    local - fs _fs="${2:-$1}"
    set +x
    while read -r d fs || [ "$d" ]; do
        [ "${fs:-$d}" = "$_fs" ] && return 0
    done < /proc/filesystems
    modprobe "$1"
}
