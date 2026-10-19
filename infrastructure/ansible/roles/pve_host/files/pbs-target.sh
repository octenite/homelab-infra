#!/bin/sh
# Runs on the hypervisor. Picks the backup server's address: the direct link
# when the server answers there, otherwise the first of the workstation's
# addresses through which it answers (E14; dock port, then Wi-Fi). The storage
# entry names the server by a hosts-file name (PVE forbids changing a
# storage's server), so switching paths means rewriting that one line.
#
#   pbs-target            one pass; prints the address in use and exits 0.
#                         With nothing answering it keeps and prints the last
#                         choice, so the backup's own error says what is wrong.
#   pbs-target --wait N   passes every ten seconds for up to N seconds until
#                         the server answers; prints the address and exits 0
#                         when it did, prints the last choice and exits 1 when
#                         it did not (N = 0 is one pass with that exit code).
#
# The failover timer and the backup both run it and both may rewrite
# /etc/hosts, so each pass holds a lock. "Unreachable" is logged when the
# server stops answering, not on every pass: under the nightly window it is
# off most of the day (backlog B51).
set -eu

# shellcheck source=/dev/null
. /etc/homelab/backup.conf

wait_s=""
case "${1:-}" in
"") ;;
--wait)
	wait_s=${2:?--wait needs a number of seconds}
	case "$wait_s" in *[!0-9]* | "")
		echo "usage: pbs-target [--wait SECONDS]" >&2
		exit 2
		;;
	esac
	;;
*)
	echo "usage: pbs-target [--wait SECONDS]" >&2
	exit 2
	;;
esac

state=/run/homelab
mkdir -p "$state"

# "Answers" means the backup server itself completes a TLS exchange. A bare
# TCP connect is not enough: on the workstation's addresses the listener is
# a Windows port forward, which accepts the connection even while the VM
# behind it is off.
reach() {
	curl --silent --insecure --output /dev/null --connect-timeout 2 --max-time 4 "https://$1:8007/"
}

current() { awk -v n="$PBS_HOSTNAME" '$2 == n { print $1; exit }' /etc/hosts; }

# One pass under the lock: prints the address chosen, or exits 1.
attempt() (
	flock 9
	server=""
	for candidate in $PBS_PRIMARY $PBS_FALLBACKS; do
		if reach "$candidate"; then
			server=$candidate
			break
		fi
	done
	[ -n "$server" ] || exit 1
	if [ "$(current)" != "$server" ]; then
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
) 9>"$state/pbs-target.lock"

deadline=$(($(date +%s) + ${wait_s:-0}))
while ! server=$(attempt); do
	if [ -z "$wait_s" ] || [ "$(date +%s)" -ge "$deadline" ]; then
		if [ ! -e "$state/pbs-unreachable" ]; then
			: >"$state/pbs-unreachable"
			logger -t homelab "backup server unreachable on every path (is the VM running?)"
		fi
		current
		[ -z "$wait_s" ] || exit 1
		exit 0
	fi
	sleep 10
done
if [ -e "$state/pbs-unreachable" ]; then
	rm -f "$state/pbs-unreachable"
	logger -t homelab "backup server answers again, on $server"
fi
echo "$server"
