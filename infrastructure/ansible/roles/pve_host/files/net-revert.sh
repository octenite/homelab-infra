#!/bin/sh
# Runs on the hypervisor from a transient systemd timer, armed before a
# network change is applied. A confirmed change removes the previous file, so
# this script then does nothing.

D=/run/homelab-net

[ -f "$D/interfaces.prev" ] || exit 0

logger -t homelab "network change not confirmed in time: restoring the previous configuration"
cp -p "$D/interfaces.prev" /etc/network/interfaces
rm -f "$D/interfaces.prev"
ifreload -a
logger -t homelab "previous network configuration restored"
