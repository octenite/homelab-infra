#!/bin/sh
# Runs on the hypervisor. Picks the backup server's address: the direct link
# when it answers, otherwise the workstation's port forward (E14), and keeps
# the storage entry in step. Prints the address in use.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf

reach() {
	timeout 3 bash -c "exec 3<>/dev/tcp/$1/8007" 2>/dev/null
}

if reach "$PBS_PRIMARY"; then
	server=$PBS_PRIMARY
else
	server=$PBS_FALLBACK
fi

current=$(pvesh get "/storage/$PBS_STORE" --output-format json | jq -r .server)
if [ "$current" != "$server" ]; then
	pvesm set "$PBS_STORE" --server "$server"
	logger -t homelab "backup target is now $server"
fi
echo "$server"
