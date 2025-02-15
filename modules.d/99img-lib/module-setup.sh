#!/bin/bash
# module-setup for img-lib

# called by dracut
check() {
    require_binaries dd echo tr || return 1
    return 255
}

# called by dracut
install() {
    inst_multiple dd echo tr
    # TODO: make this conditional on a cmdline flag / config option
    inst_multiple -o cpio xz bzip2 zstd tar gzip rmdir
    inst_simple "$moddir/img-lib.sh" "/lib/img-lib.sh"
}
