#!/bin/sh
# Runs on the OpenWrt device, started with a delay when a change is applied.
# If the change was not confirmed in time (the flag file still exists), the
# previous configuration is restored and activated.

D=/tmp/homelab-rollback

[ -f "$D/armed" ] || exit 0
rm -f "$D/armed"

logger -t homelab "change not confirmed in time: restoring the previous configuration"
cp -p "$D"/config/* /etc/config/
sh "$D/activate.sh" all
logger -t homelab "previous configuration restored"
