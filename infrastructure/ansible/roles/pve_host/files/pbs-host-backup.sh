#!/bin/sh
# Runs on the hypervisor from a timer. Backs up the host's configuration to
# the backup server, encrypted with the storage's key, over whichever path
# is up, and reports success to the dead-man's switch when one is set.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf
# shellcheck source=/dev/null
. /etc/homelab/backup.secret
export PBS_PASSWORD PBS_FINGERPRINT

server=$(/usr/local/bin/pbs-target)

proxmox-backup-client backup \
	etc.pxar:/etc \
	pve-cluster.pxar:/var/lib/pve-cluster \
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
