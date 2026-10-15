#!/bin/bash
# The WSL half of scripts/node2/travel.ps1: every step that needs the lab's
# SSH key, which lives in WSL. travel.ps1 calls one verb at a time.
#
#   travel.sh session-open      exit 0 when an operator session is open
#   travel.sh agent-start       an agent of this run's own; asks for the key's passphrase once
#   travel.sh agent-stop        that agent emptied and stopped (never the session's)
#   travel.sh key-ready         exit 0 when an agent holds the key (this run's, else the session's)
#   travel.sh where             home, away or unknown (scripts/ops/away-check.sh with that agent)
#   travel.sh container-start   start the administration container if it is stopped; wait until it runs
#   travel.sh container-stop    shut it down if it runs; wait until it is stopped
#   travel.sh health-ping       let the container report to its dead-man's switch now
#
# The agent of a run holds the SSH key only, never the age key, for at most
# LIFETIME: -Away refuses an open operator session, so that the laptop does
# not leave with the decrypted secrets in memory, yet it needs the key to
# start the container and to prove the path. travel.ps1 stops the agent when
# it ends; the lifetime is the bound if it does not.
set -uo pipefail
umask 077

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PVE=10.0.10.10
VMID=3010
RUN_DIR=/dev/shm/homelab-travel
RUN_SOCK=$RUN_DIR/agent.sock
SESSION_SOCK=$HOME/.ssh/homelab-agent.sock
KEY=$HOME/.ssh/homelab_ed25519
LIFETIME=15m

has_key() { [ -S "$1" ] && SSH_AUTH_SOCK="$1" ssh-add -l >/dev/null 2>&1; }
pick_sock() {
	if has_key "$RUN_SOCK"; then
		echo "$RUN_SOCK"
	elif has_key "$SESSION_SOCK"; then
		echo "$SESSION_SOCK"
	else
		return 1
	fi
}
# shellcheck disable=SC2029  # the command is assembled here and run on pve1
pve() {
	local s
	s=$(pick_sock) || {
		echo "no agent holds the SSH key" >&2
		return 2
	}
	SSH_AUTH_SOCK="$s" ssh -o BatchMode=yes -o ConnectTimeout=10 "ops@$PVE" "$@"
}
container_status() { pve "sudo pct status $VMID" 2>/dev/null | tr -d '\r'; }

agent_start() {
	mkdir -p "$RUN_DIR"
	if has_key "$RUN_SOCK"; then
		echo "the SSH key is loaded already"
		return 0
	fi
	pkill -u "$(id -u)" -f "ssh-agent -a $RUN_SOCK" 2>/dev/null || true
	rm -f "$RUN_SOCK"
	ssh-agent -a "$RUN_SOCK" -t "$LIFETIME" >/dev/null || return 1
	echo "The SSH key, for this run only (at most $LIFETIME; removed when travel.ps1 ends):"
	SSH_AUTH_SOCK="$RUN_SOCK" ssh-add -t "$LIFETIME" "$KEY"
}

agent_stop() {
	if [ -S "$RUN_SOCK" ]; then SSH_AUTH_SOCK="$RUN_SOCK" ssh-add -D >/dev/null 2>&1 || true; fi
	pkill -u "$(id -u)" -f "ssh-agent -a $RUN_SOCK" 2>/dev/null || true
	rm -rf "$RUN_DIR"
}

where_now() {
	local s
	s=$(pick_sock) || {
		echo unknown
		return 2
	}
	SSH_AUTH_SOCK="$s" bash "$REPO/scripts/ops/away-check.sh"
}

container_start() {
	local st
	st=$(container_status)
	case "$st" in
	*running*)
		echo "remote1 runs already"
		return 0
		;;
	*stopped*) ;;
	*)
		echo "remote1 is '${st:-not readable}'" >&2
		return 1
		;;
	esac
	pve "sudo pct start $VMID" || return 1
	for _ in $(seq 1 30); do
		case "$(container_status)" in *running*)
			echo "remote1 started"
			return 0
			;;
		esac
		sleep 2
	done
	echo "remote1 did not reach 'running' within a minute" >&2
	return 1
}

container_stop() {
	local st
	st=$(container_status)
	case "$st" in
	*stopped*)
		echo "remote1 is stopped already"
		return 0
		;;
	*running*) ;;
	*)
		echo "remote1 is '${st:-not readable}'" >&2
		return 1
		;;
	esac
	# A clean shutdown first; stopped hard if it has not ended within a minute.
	pve "sudo pct shutdown $VMID --timeout 60 --forceStop 1" || return 1
	for _ in $(seq 1 30); do
		case "$(container_status)" in *stopped*)
			echo "remote1 stopped"
			return 0
			;;
		esac
		sleep 2
	done
	echo "remote1 did not reach 'stopped'" >&2
	return 1
}

health_ping() {
	# The unit exists only when a ping address is stored (roles/remote_ct,
	# tasks/health.yaml). Exit 3 says so; 0 is a report that the tunnel is up,
	# which also resumes a paused check; 1 is a report of a failure.
	if ! pve "sudo pct exec $VMID -- systemctl cat remote-health.service" >/dev/null 2>&1; then
		echo "the container has no health timer: no ping address is stored"
		return 3
	fi
	pve "sudo pct exec $VMID -- systemctl start remote-health.service" >/dev/null 2>&1 || true
	local st
	st=$(pve "sudo pct exec $VMID -- systemctl show -p ExecMainStatus --value remote-health.service" 2>/dev/null | tr -d '\r[:space:]')
	echo "the container's health report: exit status ${st:-unknown}"
	[ "$st" = 0 ]
}

case "${1:-}" in
session-open) [ -e /dev/shm/homelab-session/age.key ] ;;
agent-start) agent_start ;;
agent-stop) agent_stop ;;
key-ready) pick_sock >/dev/null ;;
where) where_now ;;
container-start) container_start ;;
container-stop) container_stop ;;
health-ping) health_ping ;;
*)
	echo "usage: $0 session-open|agent-start|agent-stop|key-ready|where|container-start|container-stop|health-ping" >&2
	exit 2
	;;
esac
