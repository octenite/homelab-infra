#!/bin/sh
# Runs on the OpenWrt device, started with a delay when a change is applied.
# Usage: revert.sh <token>
#
# Every apply arms its own flag file, armed.<token>. This timer acts only if
# its own flag still exists. A confirmed change has no flag, and a timer left
# over from an earlier apply can never undo a later one.

D=/tmp/homelab-rollback
token=$1

[ -n "$token" ] || exit 0
[ -f "$D/armed.$token" ] || exit 0
rm -f "$D"/armed.*

logger -t homelab "change $token not confirmed in time: restoring the previous configuration"
cp -p "$D"/config/* /etc/config/
sh "$D/activate.sh" all
logger -t homelab "previous configuration restored"
