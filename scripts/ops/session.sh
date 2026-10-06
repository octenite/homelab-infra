#!/bin/bash
# The operator session: an SSH agent holding the lab key and the decrypted
# age key, both in memory only, both gone after a fixed number of hours.
#
#   session.sh start     asks for the two passphrases; run again to extend
#   session.sh end       removes the age key, unloads the SSH key, stops the agent
#   session.sh status
#
# The age key file sits in /dev/shm. That is memory, but memory can be paged
# out: see exception X23 in docs/ARCHITECTURE.md for what that means on a
# machine without disk encryption, and close the session when the work is done.
set -euo pipefail
umask 077

DIR=/dev/shm/homelab-session
SOCK="$HOME/.ssh/homelab-agent.sock"
HOURS=${HOMELAB_SESSION_HOURS:-12}

stop_timer() {
	if [ -r "$DIR/expiry.pid" ]; then
		kill "$(cat "$DIR/expiry.pid")" 2>/dev/null || true
		rm -f "$DIR/expiry.pid"
	fi
}

end() {
	stop_timer
	rm -rf "$DIR" /dev/shm/homelab-render
	if [ -S "$SOCK" ]; then
		SSH_AUTH_SOCK="$SOCK" ssh-add -D >/dev/null 2>&1 || true
		pkill -u "$(id -u)" -f "ssh-agent -a $SOCK" 2>/dev/null || true
		rm -f "$SOCK"
	fi
}

case "${1:-}" in
start)
	# ssh-add -l: 0 keys listed, 1 agent reachable but empty, 2 no agent.
	rc=0
	SSH_AUTH_SOCK="$SOCK" ssh-add -l >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 2 ]; then
		pkill -u "$(id -u)" -f "ssh-agent -a $SOCK" 2>/dev/null || true
		rm -f "$SOCK"
		ssh-agent -a "$SOCK" >/dev/null
	fi
	mkdir -p "$DIR"
	# Decrypt beside the live key and swap only when both passphrases were
	# right: a mistyped one must leave a running session, its key lifetime
	# and its timer as they were.
	rm -f "$DIR/age.key.new"
	trap 'rm -f "$DIR/age.key.new"' EXIT
	age -d -o "$DIR/age.key.new" "$HOME/.config/sops/age/operator.age"
	# Added on every start: adding a loaded key again replaces its lifetime,
	# so both halves of the session share one deadline.
	SSH_AUTH_SOCK="$SOCK" ssh-add -t "${HOURS}h" "$HOME/.ssh/homelab_ed25519"
	mv -f "$DIR/age.key.new" "$DIR/age.key"
	# The session ends by itself: a forgotten session must not stay open
	# for days on a machine that travels. The deadline is a wall-clock time,
	# so hours spent asleep with the lid closed count too.
	stop_timer
	deadline=$(($(date +%s) + HOURS * 3600))
	echo "$deadline" >"$DIR/expires"
	setsid nohup bash "$0" expire "$deadline" >/dev/null 2>&1 &
	echo "$!" >"$DIR/expiry.pid"
	echo "Session open until $(date -d "@$deadline" '+%Y-%m-%d %H:%M'). The decrypted key is in memory only. Close it with: just session-end"
	;;
expire)
	deadline=${2:?}
	while [ "$(date +%s)" -lt "$deadline" ]; do sleep 60; done
	# This process is the timer: forget its own PID before `end` would kill it.
	rm -f "$DIR/expiry.pid"
	end
	;;
end)
	end
	echo "Session closed: age key removed, SSH key unloaded, agent stopped."
	;;
status)
	if [ -r "$DIR/age.key" ]; then
		until=""
		[ -r "$DIR/expires" ] && until=" until $(date -d "@$(cat "$DIR/expires")" '+%Y-%m-%d %H:%M')"
		echo "age key: open$until"
		if ! { [ -r "$DIR/expiry.pid" ] && kill -0 "$(cat "$DIR/expiry.pid")" 2>/dev/null; }; then
			echo "WARNING: no expiry timer is running; close the session with: just session-end"
		fi
	else
		echo "age key: closed"
	fi
	if SSH_AUTH_SOCK="$SOCK" ssh-add -l >/dev/null 2>&1; then echo "ssh agent: key loaded"; else echo "ssh agent: no key"; fi
	;;
*)
	echo "usage: $0 start|end|status" >&2
	exit 2
	;;
esac
