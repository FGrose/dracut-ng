#!/bin/sh
# plymouth-lib.sh: utilities employing plymouth

# Plymouth display-message line-by-line.
# Call with IFS=<newline> "<message text>"
plym_write() {
    local - t
    set $@
    set +x
    for t; do
        plymouth display-message --text="$t"
    done
}
