#!/bin/sh
# Runs on the hypervisor. Picks the backup server's address: the direct link
# when it answers, otherwise the first of the workstation's addresses whose
# port forward answers (E14; dock port, then Wi-Fi). The storage entry names
# the server by a hosts-file name (PVE forbids changing a storage's server),
# so switching paths means rewriting that one line. Prints the address in
# use. With nothing answering it keeps the last choice, so the backup's own
# error says what is wrong.
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
current=$(awk -v n="$PBS_HOSTNAME" '$2 == n { print $1 }' /etc/hosts | head -n 1)
if [ -z "$server" ]; then
	logger -t homelab "backup server unreachable on every path"
	echo "$current"
	exit 0
fi
if [ "$current" != "$server" ]; then
	tmp=$(mktemp /etc/hosts.XXXXXX)
	awk -v n="$PBS_HOSTNAME" '$2 != n' /etc/hosts >"$tmp"
	printf '%s %s\n' "$server" "$PBS_HOSTNAME" >>"$tmp"
	chmod 644 "$tmp"
	mv "$tmp" /etc/hosts
	logger -t homelab "backup target $PBS_HOSTNAME is now $server"
fi
echo "$server"
