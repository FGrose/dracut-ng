#!/bin/sh
# non-live overlayfs images are specified with
# root=ovl:backingdev

[ "$root" ] || root=$(getarg root=)
_root="$root"

case "$root" in
    ovl:LABEL=* | ovl:UUID=* | ovl:PARTUUID=* | ovl:PARTLABEL=*)
        root=ovl:$(label_uuid_to_dev "${root#ovl:}")
        rootok=1
        ;;
    ovl:/dev/*)
        rootok=1
        ;;
esac

[ "$rootok" ] || return 1

[ "$root" = "$_root" ] || info "root was $_root, is now $root"

wait_for_dev -n /dev/root

return 0
