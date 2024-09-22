#!/bin/sh
# live .iso images are specified as
# iso-scan/filename=[<devspec>:]<filepath>

isofile=$(getarg iso-scan/filename) && /sbin/initqueue --settled --unique /sbin/iso-scan "$isofile"
