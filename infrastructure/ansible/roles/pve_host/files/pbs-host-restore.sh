#!/bin/sh
# Runs on the hypervisor. Restores one archive of a host-configuration
# backup into a directory, for inspection or for copying files back by hand.
# Usage: pbs-host-restore <snapshot|latest> <archive> <destination directory>
#   pbs-host-restore latest etc.pxar /tmp/restore
#   pbs-host-restore host/pve1-host/2026-10-06T12:35:19Z pve-cluster.pxar /tmp/restore
# The destination must not exist. "list" as the first argument lists snapshots.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf
# shellcheck source=/dev/null
. /etc/homelab/backup.secret
export PBS_PASSWORD PBS_FINGERPRINT

server=$(/usr/local/bin/pbs-target)
repo="${PBS_USER}@${server}:${PBS_DATASTORE}"
group="host/$(hostname -s)-host"

if [ "${1:-}" = "list" ]; then
	proxmox-backup-client snapshot list "$group" --repository "$repo"
	exit 0
fi

[ $# -eq 3 ] || {
	echo "usage: $0 <snapshot|latest> <archive> <destination directory>" >&2
	exit 2
}
snapshot=$1
archive=$2
dest=$3
[ ! -e "$dest" ] || {
	echo "refusing: $dest exists" >&2
	exit 1
}

if [ "$snapshot" = "latest" ]; then
	snapshot=$(proxmox-backup-client snapshot list "$group" --repository "$repo" --output-format json |
		jq -r 'sort_by(.["backup-time"]) | last | "\(.["backup-type"])/\(.["backup-id"])/\(.["backup-time"] | todate)"')
fi

mkdir -p "$dest"
chmod 700 "$dest"
proxmox-backup-client restore "$snapshot" "$archive" "$dest" --repository "$repo" --keyfile "$PBS_KEYFILE"
echo "restored $archive of $snapshot into $dest"
