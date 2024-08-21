#!/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

# Fetch non-boolean value for rd.overlay or fall back to rd.live.overlay
get_rd_overlay() {
    local rd_overlay

    rd_overlay=$(getarg rd.overlay)
    case "$rd_overlay" in
        0 | no | off | '' | 1)
            rd_overlay=$(getarg rd.live.overlay) || return 1
            warn "Kernel command line option 'rd.live.overlay' is deprecated, use 'rd.overlay' instead."
            ;;
    esac
    echo "$rd_overlay"
}
