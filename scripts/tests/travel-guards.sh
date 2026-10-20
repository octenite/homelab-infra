#!/bin/bash
# The gate of Phase R step R.9 (docs/phases/phase-r-plan.md), run at home:
# the guards that refuse real runs through the away tunnel, the short away
# session, and the backup fences with Tailscale disconnected and connected.
#
#   scripts/tests/travel-guards.sh                       (or: just test-travel)
#   scripts/tests/travel-guards.sh --with-session-start  also opens a real away session (two passphrases)
#
# Runs in WSL with a session open, at home, with the administration container
# running, the backup VM running (it is off outside its nightly window:
# Start-VM pbs1; the backup fences below need it) and Tailscale disconnected. "Away" is reproduced at home: with the
# route accepted, Windows sends the traffic for pve1 through the tunnel and
# pve1 sees the container's address, exactly as from the road. That is also
# the state in which the plan wants real runs refused at home. The tunnel is
# connected with travel.ps1 -Connect and disconnected again on every exit.
#
# Nothing on pve1 or in a state is changed: each play runs with --tags
# away-guard, so the facts and the guard are all that can run, and the
# OpenTofu and media guards refuse before anything starts. Read live and
# allowed: a dry run of the hypervisor play and two OpenTofu plans.
#
# Last, it ends the session: that is the check that an away session takes the
# tunnel with it. Start a new session afterwards if you need one.
set -uo pipefail

WITH_START=0
[ "${1:-}" = --with-session-start ] && WITH_START=1

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO" || exit 1
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
TS_EXE="/mnt/c/Program Files/Tailscale/tailscale.exe"
PS1=$(wslpath -w "$REPO/scripts/node2/travel.ps1")
LOG=$(mktemp -d /dev/shm/travel-guards.XXXXXX)

fail=0
checks=0
ok() { # <what> <expected> <got>
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		printf '  ok    %-62s %s\n' "$1" "$3"
	else
		printf '  FAIL  %-62s %s (expected %s)\n' "$1" "$3" "$2"
		fail=$((fail + 1))
	fi
}
logname() { printf '%s/%s.log' "$LOG" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; }
# <what> <allowed|refused> <the guard's words, for a refusal> <command...>
# A refusal counts only when it is the guard's, not some other failure.
expect() {
	local what=$1 want=$2 needle=$3 out rc got
	shift 3
	# No input: a probe that is not refused must fail, not wait at a prompt.
	out=$("$@" 2>&1 </dev/null)
	rc=$?
	printf '%s\n' "$out" >"$(logname "$what")"
	if [ "$rc" -eq 0 ]; then got=allowed; else got=refused; fi
	if [ "$got" = refused ] && [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then got="failed otherwise (exit $rc, $(logname "$what"))"; fi
	if [ "$got" = refused ] && [ "$want" = allowed ]; then got="refused (exit $rc, $(logname "$what"))"; fi
	ok "$what" "$want" "$got"
}
where() { bash scripts/ops/away-check.sh; }
ts_field() { # <field> <command...>: one field of the Windows client's JSON answer
	local field=$1
	shift
	"$TS_EXE" "$@" 2>/dev/null | python3 -c "import json, sys; print(json.load(sys.stdin).get('$field', ''))" 2>/dev/null | tr -d '\r'
}
travel() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "$@"; }
route_alias() { powershell.exe -NoProfile -Command "(Find-NetRoute -RemoteIPAddress 10.0.10.10 | Select-Object -First 1).InterfaceAlias" 2>/dev/null | tr -d '\r'; }
# The results as JSON, one line each, so that a message is not wrapped and the
# refusal can be matched by the address it names; and no reused SSH
# connection, so that each play really travels the path in force now.
play() { ANSIBLE_CALLBACK_RESULT_FORMAT=json ANSIBLE_SSH_ARGS='-C' bash scripts/ops/play.sh "$@"; }
tofu() { bash scripts/tofu/run.sh "$@"; }

restore() { travel -Disconnect >/dev/null 2>&1 || true; }
# The logs are kept when a check failed: the FAIL lines name them.
finish() {
	restore
	if [ "$fail" -eq 0 ]; then rm -rf "$LOG"; else echo "logs kept in $LOG"; fi
}
trap finish EXIT

echo "== before: at home, Tailscale disconnected, the container running"
if [ ! -r /dev/shm/homelab-session/age.key ]; then
	echo "No key session open. Run 'just session-start' first."
	exit 1
fi
ok "the Windows client" Stopped "$(ts_field BackendState status --json)"
ok "the administration container" running "$(ssh -o BatchMode=yes -o ConnectTimeout=10 ops@10.0.10.10 'sudo pct status 3010' 2>/dev/null | awk '{print $2}')"
ok "pve1 sees this laptop" home "$(where)"
if [ "$fail" -ne 0 ]; then
	echo "Not as the test needs it: nothing was run. Start the container with 'just remote-start', disconnect with travel.ps1 -Disconnect."
	exit 1
fi

echo "== the guard is the first task of every hypervisor play, and alone under its tag"
for p in pve pve-tokens pve-backup-init pve-bootstrap; do
	all=$(play "$p" --list-tasks 2>/dev/null)
	first=$(awk '/^ *tasks:/ { f = 1; next } f && NF { print; exit }' <<<"$all")
	ok "$p: the first task is the guard's" yes "$(grep -q 'away_guard :' <<<"$first" && echo yes || echo no)"
	tagged=$(play "$p" --list-tasks --tags away-guard 2>/dev/null)
	ok "$p: the guard's tasks under --tags away-guard" 2 "$(grep -c 'away_guard :' <<<"$tagged")"
	# The roles' argument checks run too, on the workstation; nothing else may.
	ok "$p: anything else under it but argument checks" 0 "$(grep 'TAGS: \[' <<<"$tagged" | grep -v 'play #' | grep -v 'away_guard :' | grep -vc 'Validating arguments against arg spec')"
done
ok "pve: the guard also runs under another --tags" 2 "$(play pve --list-tasks --tags node_exporter_install 2>/dev/null | grep -c 'away_guard :')"

echo "== at home, Tailscale disconnected: the guards let everything through"
ok "session length start would choose" "12 home" "$(bash scripts/ops/session.sh hours)"
for p in pve pve-tokens pve-backup-init; do
	expect "$p, a real run with only the guard" allowed '' play "$p" --tags away-guard
done
expect "OpenTofu remote plan" allowed '' tofu remote plan -input=false
expect "backup fences, Tailscale disconnected" allowed '' bash scripts/tests/backup-fences.sh

echo "== connecting the tunnel (travel.ps1 -Connect)"
expect "travel.ps1 -Connect" allowed '' travel -Connect
for _ in $(seq 1 20); do
	[ "$(where)" = away ] && break
	sleep 3
done
ok "pve1 sees this laptop" away "$(where)"
if [ "$(where)" != away ]; then
	echo "The tunnel did not take over: the checks through it are skipped."
	echo "TRAVEL GUARDS DIFFER: $fail of $checks checks disagree"
	exit 1
fi

echo "== through the tunnel: real runs refused, dry runs and plans allowed"
ok "session length start would choose" "2 away" "$(bash scripts/ops/session.sh hours)"
for p in pve pve-tokens pve-backup-init; do
	# Matched by the address read: a guard that read nothing refuses too,
	# with another message, and must not pass here.
	expect "$p, a real run with only the guard" refused "from '10.0.30.10'" play "$p" --tags away-guard
done
expect "pve, a dry run with only the guard" allowed '' play pve --check --tags away-guard
# Probes that change nothing even if their guard were broken: an apply of a
# plan file that does not exist, an import of an address that does not
# exist, and media built without a key to render its answer file.
expect "OpenTofu remote apply" refused "is not run through the away tunnel" tofu remote apply -input=false "$LOG/no-such.tfplan"
expect "OpenTofu remote import" refused "is not run through the away tunnel" tofu remote import -input=false a b
expect "OpenTofu remote plan" allowed '' tofu remote plan -input=false
expect "OpenTofu tailscale plan" allowed '' tofu tailscale plan -input=false
expect "install media: validate" refused "install media is built and written at home" env SOPS_AGE_KEY_FILE=/nonexistent bash scripts/pve/build-install-media.sh validate
# The fences' own SSH to pve1 goes through the relay now: give it longer.
expect "backup fences, Tailscale connected" allowed '' env FENCES_CONNECT_TIMEOUT=20 bash scripts/tests/backup-fences.sh

echo "== an away session takes the tunnel with it (last: this ends the session)"
if [ "$WITH_START" = 1 ]; then
	bash scripts/ops/session.sh start
	ok "the new session" "away" "$(bash scripts/ops/session.sh status | grep -q '^away session' && echo away || echo home)"
	left=$((($(cat /dev/shm/homelab-session/expires) - $(date +%s)) / 60))
	ok "its length, about two hours" yes "$([ "$left" -ge 115 ] && [ "$left" -le 121 ] && echo yes || echo "no ($left minutes)")"
else
	# What `session.sh start` writes when it opens a session through the
	# tunnel; its choice was checked above with `session.sh hours`.
	: >/dev/shm/homelab-session/away
fi
bash scripts/ops/session.sh end
ok "the Windows client after the session ended" Stopped "$(ts_field BackendState status --json)"
ok "routes accepted after the session ended" False "$(ts_field RouteAll debug prefs)"
alias=$(route_alias)
ok "pve1 is routed directly again" yes "$([ -n "$alias" ] && [ "$alias" != Tailscale ] && echo yes || echo "no (${alias:-Windows did not answer})")"

echo
if [ "$fail" -eq 0 ]; then
	echo "travel guards as designed: $checks checks, all as expected. The session is closed."
else
	echo "TRAVEL GUARDS DIFFER: $fail of $checks checks disagree. The session is closed."
	exit 1
fi
