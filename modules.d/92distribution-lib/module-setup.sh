#!/bin/bash

check() {
    return 255
}

depends() {
    # Determine distribution in order to select
    #   the appropriate <distribution>-lib dependency.
    [[ -e "${dracutsysrootdir-}/etc/os-release" ]] && {
        # shellcheck disable=SC1090
        . "${dracutsysrootdir-}/etc/os-release"
        dist="$ID"
    }
    echo base fs-lib "${dist}-lib"
}

install() {
    dracut_module_included "${dist}-lib" || {
        # Provide a stub library if one is not present:
        cat > "${initdir}/lib/distribution-lib.sh" << "E"
#!/bin/sh
# distribution-lib.sh: utilities for <distribution> image configuration

update_BootConfig() {
    [ -e /etc/os-release ] && {
        # shellcheck disable=SC1090
        . /etc/os-release
        dist="$ID"
    }
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
