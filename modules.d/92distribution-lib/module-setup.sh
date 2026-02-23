#!/bin/bash

check() {
    return 255
}

# Determine distribution in order to select
#   the appropriate <distribution>-live-lib dependency.
get_dist() {
    dist=$(get_os_release_datum ID)
    dist=${dist#\"}
    printf '%s' ${dist%\"}
}

depends() {
    echo base fs-lib "$(get_dist)"-lib
}

install() {
    dist=$(get_dist)
    dracut_module_included "$dist"-lib || {
        # Provide a stub library if one is not present:
        cat > "${initdir}/lib/distribution-lib.sh" << "E"
#!/bin/sh
# distribution-lib.sh: utilities for <distribution> image configuration

# Stub wrapper for additional filesystem flags
# $1 - fsType (ignored) $2 - flag_variable
set_FS_opts_w() {
    command -v set_FS_optionss > /dev/null || . /lib/partition-lib-min.sh
    # Call function in fs-lib.sh
    set_FS_options "$2" ''
}

update_BootConfig() {
    dist=$(get_os_release_datum ID)
    dist=${dist#\"}
    dist=${dist%\"}

    warn "*** A module for updating the boot configuration is missing. ***"
    warn "*** Expecting $dracutbasedir/modules.d/[0-9][0-9]${dist}-lib ***"
    return 1
}
E
        dwarn "*** A module for updating the boot configuration is missing. ***"
        dwarn "*** It would be needed for changes to the boot menu entries. ***"
        dwarn "*** Expecting $dracutbasedir/modules.d/[0-9][0-9]${dist}-lib ***"
    }
}
