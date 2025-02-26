#!/bin/bash
# This file is part of dracut.
# SPDX-License-Identifier: GPL-2.0-or-later

# Prerequisite check(s) for module.
check() {
    # If the binary(s) requirements are not fulfilled the module can't be installed.
    require_binaries systemd-sysusers || return 1

    # Return 255 to only include the module, if another module requires it.
    return 255
}

# Install the required file(s) and directories for the module in the initramfs.
install() {
    inst_sysusers basic.conf

    systemd-sysusers --root="$initdir" > /dev/null
}
