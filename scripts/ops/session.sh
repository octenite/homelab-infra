#!/bin/bash
# The operator session: an SSH agent holding the lab key and the decrypted
# age key, both in memory only, both gone after a fixed number of hours.
#
#   session.sh start     asks for two passphrases, first the age key's, then
#                        the SSH key's (two keys, two jobs: one decrypts the
#                        secrets, one logs in to the hosts); run again to extend
#   session.sh end       removes the age key, unloads the SSH key, stops the agent
#   session.sh status
#   session.sh hours     what `start` would choose now (needs the key loaded)
#
# Away from home a session lasts 2 hours instead of 12, and ending it, by
# hand or by its timer, also disconnects Tailscale (docs/phases/
# phase-r-plan.md, "Home and away"). Whether the laptop is away is asked of
# pve1 once the SSH key is loaded: it sees this laptop arrive through the
# tunnel, or it does not answer, which is treated as away too. Nothing about
# it is stored but a marker inside the session, gone with the session.
# HOMELAB_SESSION_HOURS sets the length in every case (at home with pve1
# down, for example); an away session still disconnects Tailscale when it ends.
#
# The age key file sits in /dev/shm. That is memory, but memory can be paged
# out: see exception X23 in docs/ARCHITECTURE.md for what that means on a
# machine without disk encryption, and close the session when the work is done.
set -euo pipefail
umask 077

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DIR=/dev/shm/homelab-session
SOCK="$HOME/.ssh/homelab-agent.sock"
HOURS=${HOMELAB_SESSION_HOURS:-12}
AWAY_HOURS=2
TS_EXE="/mnt/c/Program Files/Tailscale/tailscale.exe"
# What the timer says when it ends a session (it has no terminal); shown by
# `status`, and by the next `start`, which then removes it.
TIMER_LOG=/dev/shm/homelab-session-end.log

stop_timer() {
	if [ -r "$DIR/expiry.pid" ]; then
		kill "$(cat "$DIR/expiry.pid")" 2>/dev/null || true
		rm -f "$DIR/expiry.pid"
	fi
}

arm_timer() { # <hours>
	stop_timer
	deadline=$(($(date +%s) + $1 * 3600))
	echo "$deadline" >"$DIR/expires"
	setsid nohup bash "$0" expire "$deadline" >>"$TIMER_LOG" 2>&1 &
	echo "$!" >"$DIR/expiry.pid"
}

# Sets SESSION_HOURS and WHERE (home, away or unknown) from pve1's answer.
choose_hours() {
	WHERE=$(SSH_AUTH_SOCK="$SOCK" bash "$REPO/scripts/ops/away-check.sh") || true
	case "$WHERE" in
	home) SESSION_HOURS=$HOURS ;;
	*) SESSION_HOURS=$AWAY_HOURS ;;
	esac
	if [ -n "${HOMELAB_SESSION_HOURS:-}" ]; then SESSION_HOURS=$HOMELAB_SESSION_HOURS; fi
}

disconnect_tailscale() {
	# The Windows client is driven through WSL interop, as the Windows user
	# who runs WSL, with the vendor-safe pair only: never `up` with flags and
	# never --reset (docs/components/tailscale-client.md). Read back after:
	# the client's exit codes do not say what it holds.
	if [ ! -x "$TS_EXE" ]; then
		printf '%s\n' "WARNING: the Windows Tailscale client was not found at $TS_EXE; disconnect it yourself: scripts\\node2\\travel.ps1 -Disconnect" >&2
		return 0
	fi
	"$TS_EXE" set --accept-routes=false >/dev/null 2>&1 || true
	"$TS_EXE" down >/dev/null 2>&1 || true
	local state routes
	state=$("$TS_EXE" status --json 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin).get("BackendState", ""))' 2>/dev/null) || state=''
	state=${state%$'\r'}
	# Routes too: left accepted, the next plain "connect" (the tray menu's)
	# would send pve1's traffic through the tunnel again.
	routes=$("$TS_EXE" debug prefs 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin).get("RouteAll", ""))' 2>/dev/null) || routes=''
	routes=${routes%$'\r'}
	if [ "$state" = Stopped ] && [ "$routes" = False ]; then
		echo "Tailscale disconnected: this was an away session."
	else
		printf '%s\n' "WARNING: Tailscale reports '${state:-nothing}', routes accepted '${routes:-unknown}', after the disconnect; disconnect it yourself: scripts\\node2\\travel.ps1 -Disconnect" >&2
	fi
}

end() {
	stop_timer
	local away=0
	if [ -f "$DIR/away" ]; then away=1; fi
	rm -rf "$DIR" /dev/shm/homelab-render
	if [ -S "$SOCK" ]; then
		SSH_AUTH_SOCK="$SOCK" ssh-add -D >/dev/null 2>&1 || true
		pkill -u "$(id -u)" -f "ssh-agent -a $SOCK" 2>/dev/null || true
		rm -f "$SOCK"
	fi
	# An away session takes the tunnel with it. This also runs from the
	# timer; it does not run if WSL is shut down before the deadline, which
	# takes the keys but leaves Tailscale as it was (travel.ps1 -Home or
	# -Disconnect is the backstop; docs/components/travel-mode.md).
	if [ "$away" = 1 ]; then disconnect_tailscale; fi
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
	if [ -s "$TIMER_LOG" ]; then
		echo "The timer of an earlier session said, when it ended it:"
		sed 's/^/  /' "$TIMER_LOG"
	fi
	rm -f "$TIMER_LOG"
	# Decrypt beside the live key and swap only when both passphrases were
	# right: a mistyped one must leave a running session, its key lifetime
	# and its timer as they were.
	rm -f "$DIR/age.key.new"
	trap 'rm -f "$DIR/age.key.new"' EXIT
	age -d -o "$DIR/age.key.new" "$HOME/.config/sops/age/operator.age"
	# Added on every start: adding a loaded key again replaces its lifetime,
	# so both halves of the session share one deadline. Away, the deadline
	# below is shorter than this lifetime and is the bound: setting the
	# lifetime after asking pve1 would ask for the passphrase a second time.
	SSH_AUTH_SOCK="$SOCK" ssh-add -t "${HOURS}h" "$HOME/.ssh/homelab_ed25519"
	mv -f "$DIR/age.key.new" "$DIR/age.key"
	# The session ends by itself: a forgotten session must not stay open
	# for days on a machine that travels. The deadline is a wall-clock time,
	# so hours spent asleep with the lid closed count too. Short first, as an
	# away session: a question to pve1 that is interrupted must still leave a
	# session that ends, and that takes the tunnel with it.
	: >"$DIR/away"
	arm_timer "$AWAY_HOURS"
	echo "Asking pve1 whether this laptop is at home (up to half a minute) ..."
	choose_hours
	rm -f "$DIR/away"
	if [ "$WHERE" != home ]; then : >"$DIR/away"; fi
	if [ "$WHERE" = unknown ]; then
		echo "pve1 did not answer, so it cannot be told whether this laptop is at home: treated as away. At home with pve1 down, HOMELAB_SESSION_HOURS=12 just session-start gives the long session."
	fi
	arm_timer "$SESSION_HOURS"
	away_note=""
	if [ -f "$DIR/away" ]; then away_note=" Away session: ending it also disconnects Tailscale."; fi
	echo "Session open for $SESSION_HOURS hours, until $(date -d "@$deadline" '+%Y-%m-%d %H:%M %Z'). The decrypted key is in memory only. Close it with: just session-end.$away_note"
	;;
expire)
	deadline=${2:?}
	while [ "$(date +%s)" -lt "$deadline" ]; do sleep 60; done
	# This process is the timer: forget its own PID before `end` would kill it.
	rm -f "$DIR/expiry.pid"
	echo "$(date '+%Y-%m-%d %H:%M %Z'): the session ended at its deadline."
	end
	;;
end)
	end
	echo "Session closed: age key removed, SSH key unloaded, agent stopped."
	;;
status)
	if [ -r "$DIR/age.key" ]; then
		until=""
		[ -r "$DIR/expires" ] && until=" until $(date -d "@$(cat "$DIR/expires")" '+%Y-%m-%d %H:%M %Z')"
		echo "age key: open$until"
		if [ -f "$DIR/away" ]; then echo "away session: ending it also disconnects Tailscale"; fi
		if ! { [ -r "$DIR/expiry.pid" ] && kill -0 "$(cat "$DIR/expiry.pid")" 2>/dev/null; }; then
			echo "WARNING: no expiry timer is running; close the session with: just session-end"
		fi
	else
		echo "age key: closed"
	fi
	if SSH_AUTH_SOCK="$SOCK" ssh-add -l >/dev/null 2>&1; then echo "ssh agent: key loaded"; else echo "ssh agent: no key"; fi
	if [ -s "$TIMER_LOG" ]; then
		echo "the timer of the last session said:"
		sed 's/^/  /' "$TIMER_LOG"
	fi
	;;
hours)
	# What `start` would choose now, without starting anything; used by
	# scripts/tests/travel-guards.sh. Needs the key in the session's agent.
	choose_hours
	echo "$SESSION_HOURS $WHERE"
	;;
*)
	echo "usage: $0 start|end|status|hours" >&2
	exit 2
	;;
esac
