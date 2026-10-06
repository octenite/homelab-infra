#!/bin/sh
# Runs on the hypervisor. Picks the backup server's address: the direct link
# when it answers, otherwise the first of the workstation's addresses whose
# port forward answers (E14; dock port, then Wi-Fi), and keeps the storage
# entry in step. Prints the address in use. With nothing answering it keeps
# the last choice, so the backup's own error says what is wrong.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf

reach() {
	timeout 3 bash -c "exec 3<>/dev/tcp/$1/8007" 2>/dev/null
}

server=""
for candidate in $PBS_PRIMARY $PBS_FALLBACKS; do
	if reach "$candidate"; then
		server=$candidate
		break
	fi
done
if [ -z "$server" ]; then
	logger -t homelab "backup server unreachable on every path"
	pvesh get "/storage/$PBS_STORE" --output-format json | jq -r .server
	exit 0
fi

current=$(pvesh get "/storage/$PBS_STORE" --output-format json | jq -r .server)
if [ "$current" != "$server" ]; then
	pvesm set "$PBS_STORE" --server "$server"
	logger -t homelab "backup target is now $server"
fi
echo "$server"
