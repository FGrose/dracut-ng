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
    echo base "$(get_dist)"-live-lib
}

install() {
    dist=$(get_dist)
    dracut_module_included "$dist"-live-lib || {
        # Provide a stub library if one is not present:
        cat > "${initdir}/lib/distribution-live-lib.sh" << "E"
#!/bin/sh
# distribution-lib.sh: utilities for <distribution> image configuration

# Filesystem flags for the persistence partition bearing a root OverlayFS
set_FS_options() {
    p_ptFlags=$(getarg rd.ovl.flags)
}

update_BootConfig() {
    dist=$(get_os_release_datum ID)
    dist=${dist#\"}
    dist=${dist%\"}

    warn "*** A module for updating the boot configuration is missing. ***"
    warn "*** Expecting $dracutbasedir/modules.d/[0-9][0-9]${dist}-live-lib ***"
    return 1
}
E
        dwarn "*** A module for updating the boot configuration is missing. ***"
        dwarn "*** It would be needed for changes to the boot menu entries. ***"
        dwarn "*** Expecting $dracutbasedir/modules.d/[0-9][0-9]${dist}-live-lib ***"
    }
}
