#!/bin/sh
# Runs on the hypervisor. Picks the backup server's address: the direct link
# when the server answers there, otherwise the first of the workstation's
# addresses through which it answers (E14; dock port, then Wi-Fi). The storage
# entry names the server by a hosts-file name (PVE forbids changing a
# storage's server), so switching paths means rewriting that one line.
# Prints the address in use. With nothing answering it keeps the last choice,
# so the backup's own error says what is wrong.
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf

# "Answers" means the backup server itself completes a TLS exchange. A bare
# TCP connect is not enough: on the workstation's addresses the listener is
# a Windows port forward, which accepts the connection even while the VM
# behind it is off.
reach() {
	curl --silent --insecure --output /dev/null --connect-timeout 2 --max-time 4 "https://$1:8007/"
}

server=""
for candidate in $PBS_PRIMARY $PBS_FALLBACKS; do
	if reach "$candidate"; then
		server=$candidate
		break
	fi
done
current=$(awk -v n="$PBS_HOSTNAME" '$2 == n { print $1; exit }' /etc/hosts)
if [ -z "$server" ]; then
	logger -t homelab "backup server unreachable on every path (is the VM running?)"
	echo "$current"
	exit 0
fi
if [ "$current" != "$server" ]; then
	tmp=$(mktemp /etc/hosts.XXXXXX)
	trap 'rm -f "$tmp"' EXIT
	awk -v n="$PBS_HOSTNAME" '$2 != n' /etc/hosts >"$tmp"
	printf '%s %s\n' "$server" "$PBS_HOSTNAME" >>"$tmp"
	chmod 644 "$tmp"
	mv "$tmp" /etc/hosts
	trap - EXIT
	logger -t homelab "backup target $PBS_HOSTNAME is now $server"
fi
echo "$server"
