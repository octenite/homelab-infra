#!/bin/sh
# Runs on the hypervisor after each pass of the failover timer
# (pbs-failover.service). Starts the host backup when one is due: the last
# success is older than PBS_DUE_HOURS, no backup is running, and the backup
# server answers now. A daytime start of the backup VM is then the whole
# catch-up of a missed night, and a backup that a restart of the workstation
# cut short is done again once the VM is back (backlog B51). At most one start
# per PBS_DUE_BACKOFF_MINUTES, so a backup that keeps failing is not retried
# every five minutes.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf

now=$(date +%s)
# Nothing is due before the first success on this host: after a rebuild of
# pve1 the record does not exist, and a backup of the not yet restored host
# would become the day's newest snapshot, which the daily prune keeps in
# place of the last good one. The record is written by a real success: the
# nightly timer, or the hand-run backup that ends the restore runbook.
[ -s /var/lib/homelab/host-backup.last ] || exit 0
last=$(cat /var/lib/homelab/host-backup.last)
case "$last" in *[!0-9]*) exit 0 ;; esac
[ $((now - last)) -ge $((PBS_DUE_HOURS * 3600)) ] || exit 0
# A backup that runs holds this lock (a Type=oneshot unit reads "activating",
# not "active", while it runs, so systemctl cannot tell).
mkdir -p /run/homelab
flock -n /run/homelab/pbs-host-backup.lock true || exit 0

tried=$(cat /run/homelab/pbs-due.tried 2>/dev/null || echo 0)
case "$tried" in *[!0-9]* | "") tried=0 ;; esac
[ $((now - tried)) -ge $((PBS_DUE_BACKOFF_MINUTES * 60)) ] || exit 0

/usr/local/bin/pbs-target --wait 0 >/dev/null || exit 0

echo "$now" >/run/homelab/pbs-due.tried
logger -t homelab "host backup due (last success $(date -d "@$last" '+%F %R')); starting it"
systemctl start --no-block pbs-host-backup.service
