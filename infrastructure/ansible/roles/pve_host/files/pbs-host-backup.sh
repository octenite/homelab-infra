#!/bin/sh
# Runs on the hypervisor from a timer. Backs up the host's configuration to
# the backup server, encrypted with the storage's key, over whichever path
# is up, and reports success to the dead-man's switch when one is set. Any
# failure exits before that report, so a missing report means a missing
# backup.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf
# shellcheck source=/dev/null
. /etc/homelab/backup.secret
export PBS_PASSWORD PBS_FINGERPRINT

server=$(/usr/local/bin/pbs-target)
[ -n "$server" ] || {
	echo "no address recorded for $PBS_HOSTNAME" >&2
	exit 1
}

# The cluster database is a live SQLite file in write-ahead-log mode: most
# recent changes sit in config.db-wal, and copying the three files one by
# one gives a set that may not belong together. SQLite's own backup takes
# one consistent file, which is what gets archived (and what a restore puts
# back, see docs/runbooks/restore-host-config.md).
stage=/var/lib/homelab/pve-cluster
rm -rf "$stage"
mkdir -p "$stage"
chmod 700 "$stage"
trap 'rm -rf "$stage"' EXIT
sqlite3 /var/lib/pve-cluster/config.db ".timeout 10000" ".backup '$stage/config.db'"
check=$(sqlite3 "$stage/config.db" 'pragma integrity_check;')
[ "$check" = ok ] || {
	echo "the copy of the cluster database failed its integrity check: $check" >&2
	exit 1
}

proxmox-backup-client backup \
	etc.pxar:/etc \
	pve-cluster.pxar:"$stage" \
	root.pxar:/root \
	--include-dev /etc/pve \
	--exclude '*.iso' \
	--repository "${PBS_USER}@${server}:${PBS_DATASTORE}" \
	--keyfile "$PBS_KEYFILE" \
	--backup-id "$(hostname -s)-host"

if [ -n "${PING_URL:-}" ]; then
	curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL" || logger -t homelab "backup ping failed"
fi
logger -t homelab "host configuration backed up to $server"
