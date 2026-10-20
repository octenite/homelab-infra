#!/bin/sh
# Runs on the hypervisor from a timer, from the failover timer when a backup
# is due (pbs-due), or by hand. Backs up the host's configuration to the
# backup server, encrypted with the storage's key, over whichever path is up,
# and reports success to the dead-man's switch when one is set. Any failure
# exits before that report, so a missing report means a missing backup.
#
# The backup server is a VM on the workstation that runs for a nightly window
# (backlog B51). Inside the window (PBS_RETRY_FROM to PBS_RETRY_UNTIL, local
# time) a run waits for the server and tries again every minute until the
# window ends: the VM may still be starting, and a restart of the workstation
# can cut a run short. Outside it, one wait of two minutes and one attempt.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf
# shellcheck source=/dev/null
. /etc/homelab/backup.secret
export PBS_PASSWORD PBS_FINGERPRINT

mkdir -p /run/homelab
exec 8>/run/homelab/pbs-host-backup.lock
flock -n 8 || {
	echo "another host backup is running" >&2
	exit 1
}

now=$(date +%s)
day=$(date +%F)
from=$(date -d "$day $PBS_RETRY_FROM" +%s)
until=$(date -d "$day $PBS_RETRY_UNTIL" +%s)
if [ "$now" -ge "$from" ] && [ "$now" -lt "$until" ]; then
	window=yes
	deadline=$until
else
	window=no
	deadline=$((now + 120))
fi

# The cluster database is a live SQLite file in write-ahead-log mode: most
# recent changes sit in config.db-wal, and copying the three files one by
# one gives a set that may not belong together. SQLite's own backup takes
# one consistent file, which is what gets archived (and what a restore puts
# back, see docs/runbooks/restore-host-config.md).
stage=/var/lib/homelab/pve-cluster
trap 'rm -rf "$stage"' EXIT

# One attempt; returns non-zero on any failure. (set -e does not apply inside
# a function called as a condition, so every step is checked.)
attempt() { # <seconds to wait for the server>
	server=$(/usr/local/bin/pbs-target --wait "$1") || {
		echo "the backup server did not answer within $1 s" >&2
		return 1
	}
	rm -rf "$stage" && mkdir -p "$stage" && chmod 700 "$stage" || return 1
	sqlite3 /var/lib/pve-cluster/config.db ".timeout 10000" ".backup '$stage/config.db'" || return 1
	check=$(sqlite3 "$stage/config.db" 'pragma integrity_check;') || return 1
	[ "$check" = ok ] || {
		echo "the copy of the cluster database failed its integrity check: $check" >&2
		return 1
	}
	# A bound on the client: a connection that a restart of the workstation
	# leaves half open must end the attempt, not the window.
	timeout -k 30 "${PBS_CLIENT_TIMEOUT:-900}" proxmox-backup-client backup \
		etc.pxar:/etc \
		pve-cluster.pxar:"$stage" \
		root.pxar:/root \
		--include-dev /etc/pve \
		--exclude '*.iso' \
		--repository "${PBS_USER}@${server}:${PBS_DATASTORE}" \
		--keyfile "$PBS_KEYFILE" \
		--backup-id "$(hostname -s)-host" || return 1
}

tries=0
while :; do
	tries=$((tries + 1))
	left=$((deadline - $(date +%s)))
	[ "$left" -gt 0 ] || left=0
	if attempt "$left"; then
		break
	fi
	if [ "$window" = no ] || [ "$(date +%s)" -ge "$deadline" ]; then
		echo "no backup: $tries attempt(s), the last one failed" >&2
		exit 1
	fi
	logger -t homelab "host backup attempt $tries failed; trying again in a minute (until $PBS_RETRY_UNTIL)"
	sleep 60
done

# The time of the last success, for pbs-due.
date +%s >/var/lib/homelab/host-backup.last
if [ -n "${PING_URL:-}" ]; then
	curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL" || logger -t homelab "backup ping failed"
fi
logger -t homelab "host configuration backed up to $server (attempt $tries)"
