#!/bin/sh
# plymouth-lib.sh: utilities employing plymouth

# Plymouth display-message line-by-line.
plym_write() {
    local - t
    set +x
    for t; do
        plymouth display-message --text="$t"
    done
}
