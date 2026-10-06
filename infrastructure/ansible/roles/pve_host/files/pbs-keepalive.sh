#!/bin/sh
# Runs on the hypervisor as a service. The workstation's USB 2.5 GbE adapter
# powers its link down after about ten seconds without traffic and does not
# bring it back by itself (measured 2026-10-06), so a small packet every few
# seconds keeps the direct link up. Unanswered is fine: the frame arriving
# at the adapter is what matters.
set -u

# shellcheck source=/dev/null
. /etc/homelab/backup.conf

while true; do
	ping -c 1 -W 1 -q "$PBS_PRIMARY" >/dev/null 2>&1 || true
	sleep "${PBS_KEEPALIVE_SECONDS:-5}"
done
