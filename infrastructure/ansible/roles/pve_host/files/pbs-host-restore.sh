#!/bin/sh
# Runs on the hypervisor. Restores one archive of a host-configuration
# backup into a new directory, for inspection or for copying files back by
# hand; it never writes onto a live path.
#
#   pbs-host-restore list
#   pbs-host-restore <snapshot> <archive> <destination directory>
#   pbs-host-restore latest <archive> <destination directory>
#
# Archives: etc.pxar, pve-cluster.pxar (one consistent config.db), root.pxar.
# "latest" is refused when the newest snapshot was taken after this system
# was installed and older ones exist: on a rebuilt host the newest snapshot
# is the rebuilt, empty host, not the state to recover. Name the snapshot.
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
	echo "usage: $0 list | <snapshot|latest> <archive> <destination directory>" >&2
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
	listing=$(proxmox-backup-client snapshot list "$group" --repository "$repo" --output-format json)
	# Finished snapshots only: an interrupted one has no size.
	times=$(printf '%s' "$listing" | jq -r '[.[] | select(.size != null and .size > 0) | .["backup-time"]] | sort | .[]')
	[ -n "$times" ] || {
		echo "no finished snapshot in $group" >&2
		exit 1
	}
	newest=$(printf '%s\n' "$times" | tail -n 1)
	count=$(printf '%s\n' "$times" | wc -l)
	installed=$(stat -c %W /etc/machine-id 2>/dev/null || echo 0)
	[ "$installed" -gt 0 ] || installed=$(stat -c %Y /etc/machine-id)
	if [ "$newest" -gt "$installed" ] && [ "$count" -gt 1 ] && [ "$(printf '%s\n' "$times" | head -n 1)" -lt "$installed" ]; then
		echo "refusing 'latest': the newest snapshot was taken after this system was installed, and older ones exist." >&2
		echo "On a rebuilt host the state to recover is an older one. List them and name one:" >&2
		echo "  $0 list" >&2
		exit 1
	fi
	snapshot="$group/$(date -u -d "@$newest" +%Y-%m-%dT%H:%M:%SZ)"
fi

echo "restoring $archive of $snapshot into $dest"
mkdir -p "$dest"
chmod 700 "$dest"
proxmox-backup-client restore "$snapshot" "$archive" "$dest" --repository "$repo" --keyfile "$PBS_KEYFILE"
echo "restored $archive of $snapshot into $dest"
