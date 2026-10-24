#!/system/bin/sh
MODDIR=${0%/*}
exec sh "$MODDIR/scripts/ctl.sh" status
