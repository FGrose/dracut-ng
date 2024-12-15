#!/bin/bash

check() {
    return 255
}

install() {
    inst_simple "$moddir/fedora-lib.sh" "/lib/distribution-lib.sh"
}
