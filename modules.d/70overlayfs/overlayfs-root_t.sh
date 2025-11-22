#!/bin/sh -x

# Change SELinux context type for root & OverlayFS directories on virtual filesystems.
chcon -t root_t / /run/overlayfs /run/ovlwork

# Restore contexts changed in overlayfs-pre-pivot-actions.sh, which added
#  content to /usr/bin and /usr/lib/systemd/system in the OverlayFS.
chcon -t usr_t /usr
chcon -t lib_t /usr/lib /usr/lib/systemd
chcon -t bin_t /usr/bin /usr/bin/overlayfs-root_t.sh
chcon -h -t systemd_unit_file_t /usr/lib/systemd/system \
    /usr/lib/systemd/system/overlayfs-root_t.service \
    /usr/lib/systemd/system/local-fs-pre.target.wants \
    /usr/lib/systemd/system/local-fs-pre.target.wants/overlayfs-root_t.service
