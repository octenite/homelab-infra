#!/bin/bash
# The outside-network test of Phase R step R.10 (docs/phases/phase-r-plan.md,
# "Tests"): the laptop on a phone hotspot, in an away session, reaches pve1's
# SSH and web interface through the administration container and nothing
# else, over a relayed path (D8). Read-only on every device: it opens and
# closes connections, reads logs and counters, and runs one dry run.
#
#   scripts/tests/travel-outside.sh          (or: just test-outside)  checks 0 to 11
#   scripts/tests/travel-outside.sh netcheck at home, before -Away: the home NAT, for the speed drill
#   scripts/tests/travel-outside.sh web      brackets the owner's browser check: web interface and console
#   scripts/tests/travel-outside.sh phone    brackets the owner's phone check: the phone reaches nothing
#   scripts/tests/travel-outside.sh end      ends the away session; checks the tunnel went with it
#
# Runs in WSL away from home, after travel.ps1 -Away at home and `just
# session-start` through the tunnel. The order of the day:
# docs/components/travel-mode.md, "Testing from outside".
#
# Through the tunnel a refusal is never a reset: the container drops what the
# policy does not grant and answers nothing, so a refused port reads
# "filtered" here. The layer that refused is read inside the container, in
# its daemon's log: a "Drop:" line is the policy; "could not connect to local
# backend server" means the policy let the connection through, which fails
# the test.
set -uo pipefail

VERB=${1:-run}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO" || exit 1
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
VMID=3010
ADDR=10.0.30.10
PVE=10.0.10.10
ROUTER=192.168.1.53
P2P_PVE=10.0.99.1
SESSION=/dev/shm/homelab-session
TS_EXE="/mnt/c/Program Files/Tailscale/tailscale.exe"
POLICY=infrastructure/opentofu/roots/tailscale/policy.hujson
# The hotspot's network must overlap none of these: the home network, every
# lab range (10.0.<VLAN>.0/24, the direct link, the backup NAT) and WSL's own.
LAB_NETS="192.168.1.0/24 10.0.0.0/16 $(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4; exit}')"
# Ports on pve1 the policy does not grant. Some really listen on pve1
# (85, 111, 3128, 8007 on the direct link, 9100, 9633), so a pass is not an
# accident of nothing listening.
DENIED_PORTS="25 80 85 111 443 3128 3389 5900 8007 9100 9633"

host_of() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\([0-9.]*\)\".*/\1/p" "$POLICY"; }
LAPTOP_TS=$(host_of laptop)
PHONE_TS=$(host_of phone)
REMOTE1_TS=$(host_of remote1)
# The routes the policy approves: what the laptop must accept, and nothing more.
WANT_ROUTES=$(sed -n '/"autoApprovers"/,/^\t},/p' "$POLICY" | grep -oE '"[0-9.]+/[0-9]+"' | tr -d '"' | sort | xargs)

LOG=$(mktemp -d /dev/shm/travel-outside.XXXXXX)
SUMMARY=$LOG/summary.txt
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
rec() { # <what> <value>: recorded for the gate, not judged
	printf '  rec   %-62s %s\n' "$1" "$2"
	printf '%s: %s\n' "$1" "$2" >>"$SUMMARY"
}
logname() { printf '%s/%s.log' "$LOG" "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"; }
# <what> <allowed|refused> <the guard's words, for a refusal> <command...>
expect() {
	local what=$1 want=$2 needle=$3 out rc got
	shift 3
	out=$("$@" 2>&1 </dev/null)
	rc=$?
	printf '%s\n' "$out" >"$(logname "$what")"
	if [ "$rc" -eq 0 ]; then got=allowed; else got=refused; fi
	if [ "$got" = refused ] && [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then got="failed otherwise (exit $rc, $(logname "$what"))"; fi
	if [ "$got" = refused ] && [ "$want" = allowed ]; then got="refused (exit $rc, $(logname "$what"))"; fi
	ok "$what" "$want" "$got"
}
play() { ANSIBLE_CALLBACK_RESULT_FORMAT=json ANSIBLE_SSH_ARGS='-C' bash scripts/ops/play.sh "$@"; }
tofu() { bash scripts/tofu/run.sh "$@"; }
# Through the relay: longer timeouts, and a stall of a minute ends the
# connection. No compression, so the copies below are not flattered.
pve() { ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 -o Compression=no "ops@$PVE" "$@"; }
# One command inside the container, read through pve1 (the laptop's grant
# does not reach the container itself). It reads; it changes nothing.
# shellcheck disable=SC2029  # assembled here, run there
ct() { pve "sudo pct exec $VMID -- sh -c $(printf '%q' "$1")"; }
probe() { # <host> <port> <seconds> -> open | refused | filtered | unreachable
	local out rc
	out=$(timeout "$3" bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
	rc=$?
	case $rc in 0) echo open ;; 124) echo filtered ;; *) case "$out" in *refused*) echo refused ;; *) echo unreachable ;; esac ;; esac
}
win() { powershell.exe -NoProfile -NonInteractive -Command "$1" 2>/dev/null | tr -d '\r'; }
ts_json() { "$TS_EXE" "$@" 2>/dev/null | tr -d '\r'; }
# What Windows says about this laptop's networks, one key=value per line.
win_facts() {
	# shellcheck disable=SC2016  # PowerShell's variables
	win '$a = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue)
"home=" + (@($a | Where-Object { $_.IPAddress -like "192.168.1.*" } | ForEach-Object IPAddress) -join ",")
"p2p=" + (@($a | Where-Object { $_.IPAddress -eq "10.0.99.2" } | ForEach-Object InterfaceAlias) -join ",")
"up=" + (@(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq Up | ForEach-Object Name | Sort-Object) -join ",")
$d = @(Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction SilentlyContinue)[0]
"uplink=" + $d.InterfaceAlias + " " + $d.IPAddress + "/" + $d.PrefixLength
"pve1=" + @(Find-NetRoute -RemoteIPAddress 10.0.10.10 -ErrorAction SilentlyContinue)[0].InterfaceAlias
"tsmtu=" + (Get-NetIPInterface -InterfaceAlias Tailscale -AddressFamily IPv4 -ErrorAction SilentlyContinue).NlMtu'
}
fact() { sed -n "s/^$1=//p" <<<"$2" | head -n 1; }
# Overlap of one network with any in LAB_NETS: prints the first it meets.
overlap() {
	python3 -I -c 'import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1], strict=False)
print(next((m for m in sys.argv[2].split() if n.overlaps(ipaddress.ip_network(m, strict=False))), ""))' "$1" "$LAB_NETS" 2>/dev/null || echo "unreadable"
}
# The fields of `tailscale netcheck --format=json` that the speed drill
# reads. It reports the carrier's public address too: never printed here.
NC_FIELDS='import json, sys
d = json.load(sys.stdin)
lat = d.get("RegionLatency") or {}
pref = d.get("PreferredDERP")
print("UDP=%s MappingVariesByDestIP=%s PreferredDERP=%s (%.0f ms)" % (d.get("UDP"), d.get("MappingVariesByDestIP"), pref, (lat.get(str(pref)) or 0) / 1e6))'

finish() {
	echo
	echo "logs and the summary: $LOG (memory only: copy summary.txt into the gate record before WSL stops)"
}
trap finish EXIT

# ---- 0: what the test needs ----------------------------------------------------
preconditions() {
	if [ ! -r "$SESSION/age.key" ]; then
		echo "No key session open. Run 'just session-start' first, through the tunnel."
		exit 1
	fi
	if [ ! -f "$SESSION/away" ]; then
		echo "This session was opened on the direct path (12 hours, its end does not disconnect Tailscale)."
		echo "Run 'just session-end', then 'just session-start' through the tunnel."
		exit 1
	fi
	if [ ! -x "$TS_EXE" ]; then
		echo "The Windows Tailscale client is not at $TS_EXE."
		exit 1
	fi
	if [ -z "$LAPTOP_TS" ] || [ -z "$REMOTE1_TS" ] || [ -z "$WANT_ROUTES" ]; then
		echo "Could not read the addresses or the approved routes from $POLICY."
		exit 1
	fi
}

the_client() {
	local st prefs
	st=$(ts_json status --json)
	prefs=$(ts_json debug prefs)
	python3 -I -c 'import json, sys
s = json.loads(sys.argv[1] or "{}"); p = json.loads(sys.argv[2] or "{}")
print("backend=%s" % s.get("BackendState", ""))
print("prefs=%s %s %s %s %s %s" % (p.get("WantRunning"), p.get("RouteAll"), p.get("ShieldsUp"), p.get("CorpDNS"), p.get("RunSSH"), p.get("ExitNodeID") or "-"))
print("self=%s" % ((s.get("Self") or {}).get("TailscaleIPs") or [""])[0])
print("advertised=%s" % ",".join(p.get("AdvertiseRoutes") or []))' "$st" "$prefs" 2>/dev/null
}

really_outside() { # <label>: the checks that the laptop is off the home networks
	local f
	f=$(win_facts)
	ok "$1: no address on the home network" "" "$(fact home "$f")"
	ok "$1: no physical link but the Wi-Fi" Wi-Fi "$(fact up "$f")"
	ok "$1: pve1 is routed through the tunnel" Tailscale "$(fact pve1 "$f")"
	ok "$1: the direct link answers nothing" yes "$(case "$(probe "$P2P_PVE" 22 3)" in filtered | unreachable) echo yes ;; *) echo no ;; esac)"
	# An answer from the router, even a reset, means the hotspot's upstream is
	# the home Wi-Fi: the phone's own Wi-Fi is on.
	ok "$1: the home router answers nothing" yes "$(case "$(probe "$ROUTER" 22 3)" in filtered | unreachable) echo yes ;; *) echo no ;; esac)"
	ok "$1: pve1 sees this laptop arrive through the tunnel" away "$(bash scripts/ops/away-check.sh)"
	FACTS=$f
}

run_all() {
	preconditions
	echo "R.10 outside test, $(date '+%Y-%m-%d %H:%M %Z')" >"$SUMMARY"
	echo "== 0. the session and the client"
	left=$((($(cat "$SESSION/expires") - $(date +%s)) / 60))
	ok "at least 45 minutes left in the session" yes "$([ "$left" -ge 45 ] && echo yes || echo "no ($left minutes)")"
	c=$(the_client)
	ok "the Windows client" Running "$(fact backend "$c")"
	# On, routes accepted, incoming refused, no name service, no SSH server, no exit node.
	ok "its preferences (on routes shields dns ssh exit)" "True True True False False -" "$(fact prefs "$c")"
	ok "this laptop's tailnet address is the policy's" "$LAPTOP_TS" "$(fact self "$c")"
	ok "this laptop advertises no route" "" "$(fact advertised "$c")"

	echo "== 1. really outside"
	really_outside before
	up=$(fact uplink "$FACTS")
	rec "the uplink" "$up"
	ok "the hotspot's network overlaps no lab network" "" "$(overlap "${up##* }")"
	rec "the direct link's address still held by" "$(fact p2p "$FACTS")"
	ok "WSL networking mode" nat "$(wslinfo --networking-mode 2>/dev/null | tr -d '\r')"
	rec "WSL eth0 MTU" "$(cat /sys/class/net/eth0/mtu 2>/dev/null)"
	rec "Tailscale adapter MTU" "$(fact tsmtu "$FACTS")"
	# shellcheck disable=SC2016  # PowerShell's variable
	rec "the Wi-Fi network" "$(win '(netsh.exe wlan show interfaces) -match "^\s+SSID\s+:" | ForEach-Object { ($_ -split ":", 2)[1].Trim() }' | head -n 1)"

	echo "== 2. SSH works, and pve1's log names this session"
	# shellcheck disable=SC2016  # expanded on pve1
	conn=$(pve 'set -- $SSH_CONNECTION; echo "conn $1 $2"; sleep 2; s=$(( $(date +%s) - 300 )); echo "line $(sudo journalctl -t sshd-session -t sshd -t sshd-auth --since "@$s" --no-pager -o cat | grep -F "Accepted publickey for ops from $1 port $2 ssh2:" | tail -n 1)"; echo "unit $(sudo journalctl -u ssh.service --since "@$s" --no-pager -o cat | grep -cF "from $1 port $2 ssh2:")"' 2>/dev/null)
	from=$(sed -n 's/^conn \([^ ]*\) .*/\1/p' <<<"$conn")
	port=$(sed -n 's/^conn [^ ]* \([0-9]*\)$/\1/p' <<<"$conn")
	line=$(sed -n 's/^line //p' <<<"$conn")
	ok "pve1 sees the SSH come from the container" "$ADDR" "$from"
	ok "pve1's log has the login, by its source port" yes "$([ -n "$port" ] && grep -qF "port $port ssh2:" <<<"$line" && echo yes || echo no)"
	fp=$(grep -oE 'SHA256:[A-Za-z0-9+/=]+' <<<"$line" | head -n 1)
	ok "with the key this session holds" yes "$([ -n "$fp" ] && ssh-add -l -E sha256 2>/dev/null | grep -qF "$fp" && echo yes || echo no)"
	rec "pve1's login line" "${line:-none}"
	rec "the same line seen by journalctl -u ssh.service" "$(sed -n 's/^unit //p' <<<"$conn")"

	echo "== 3. the accepted routes are the approved ones, and nothing more"
	# Windows' own prefixes and the tailnet's are set aside: its peers' /32s,
	# 100.100.100.100, multicast, broadcast, link-local.
	got=$(win 'Get-NetRoute -InterfaceAlias Tailscale -PolicyStore ActiveStore -ErrorAction SilentlyContinue | ForEach-Object DestinationPrefix' |
		python3 -I -c 'import ipaddress, sys
own = [ipaddress.ip_network(n) for n in ("100.64.0.0/10", "fd7a:115c:a1e0::/48", "224.0.0.0/4", "255.255.255.255/32", "169.254.0.0/16", "ff00::/8", "fe80::/10")]
left = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    n = ipaddress.ip_network(line, strict=False)
    if not any(n.version == o.version and n.subnet_of(o) for o in own):
        left.add(str(n))
print(" ".join(sorted(left)))')
	ok "routes on the Tailscale adapter beyond the tailnet's own" "$WANT_ROUTES" "$got"
	rec "routes beyond the tailnet's own" "$got"
	peers=$(ts_json status --json | python3 -I -c 'import json, sys
d = json.load(sys.stdin)
peers = list((d.get("Peer") or {}).values())
routes = sorted({r for p in peers for r in (p.get("PrimaryRoutes") or [])})
holders = sorted({"%s:%s" % (p.get("HostName"), ",".join(p.get("Tags") or [])) for p in peers if p.get("PrimaryRoutes")})
print("routes=" + " ".join(routes))
print("holders=" + " ".join(holders))
print("exit=%d" % sum(1 for p in peers if p.get("ExitNode")))
print("self=" + ",".join((d.get("Self") or {}).get("PrimaryRoutes") or []))' 2>/dev/null)
	ok "every route any peer serves" "$WANT_ROUTES" "$(fact routes "$peers")"
	ok "served by remote1 with its tag, and no one else" "remote1:tag:remote-admin" "$(fact holders "$peers")"
	ok "no exit node in use" 0 "$(fact exit "$peers")"
	ok "this laptop serves no route" "" "$(fact self "$peers")"
	# shellcheck disable=SC2016  # PowerShell's variables
	others=$(win 'foreach ($t in "10.0.10.1", "10.0.10.2", "10.0.30.10", "10.0.31.10", "10.0.50.201", "192.168.1.53") { $r = @(Find-NetRoute -RemoteIPAddress $t -ErrorAction SilentlyContinue)[0]; if ($r.InterfaceAlias -eq "Tailscale") { $t } }' | xargs)
	ok "no other lab address is routed through the tunnel" "" "$others"

	echo "== 4. relayed, never direct (D8), and the delay"
	path=$(ts_json status --json | python3 -I -c 'import json, sys
d = json.load(sys.stdin)
r = [p for p in (d.get("Peer") or {}).values() if p.get("HostName") == "remote1" and p.get("Online")]
p = r[0] if r else {}
print("found=%d" % len(r))
print("ip=%s" % (p.get("TailscaleIPs") or [""])[0])
print("direct=%s" % (p.get("CurAddr") or "-"))
print("peerrelay=%s" % (p.get("PeerRelay") or "-"))
print("home=%s" % (p.get("Relay") or "-"))
print("selfhome=%s" % ((d.get("Self") or {}).get("Relay") or "-"))' 2>/dev/null)
	ok "remote1 online, once" 1 "$(fact found "$path")"
	ok "its tailnet address is the policy's (hosts.remote1)" "$REMOTE1_TS" "$(fact ip "$path")"
	ok "no direct path to it" - "$(fact direct "$path")"
	ok "no peer relay either: a DERP relay" - "$(fact peerrelay "$path")"
	rec "home DERP regions (remote1, this laptop)" "$(fact home "$path"), $(fact selfhome "$path")"
	pings=$("$TS_EXE" ping -c 5 --until-direct=false "$(fact ip "$path")" 2>&1 | tr -d '\r')
	printf '%s\n' "$pings" >"$LOG/ping.log"
	ok "five answers, each through a DERP relay" 5 "$(grep -c 'via DERP(' <<<"$pings")"
	rec "tailscale ping (relay, min/median/max ms)" "$(python3 -I -c 'import re, statistics, sys
t = sys.stdin.read()
via = sorted(set(re.findall(r"via (DERP\([^)]*\))", t)))
ms = []
for v, u in re.findall(r" in ([0-9.]+)(ms|s|µs)", t):
    ms.append(float(v) * {"ms": 1, "s": 1000, "µs": 0.001}[u])
print("%s %s" % (",".join(via) or "none", "%.0f/%.0f/%.0f" % (min(ms), statistics.median(ms), max(ms)) if ms else "no answers"))' <<<"$pings")"
	rec "netcheck, this laptop on the hotspot" "$(ts_json netcheck --format=json | python3 -I -c "$NC_FIELDS" 2>/dev/null)"
	# Proves only that the daemon's user has no UDP out: with STUN dropped,
	# its MappingVariesByDestIP stays empty. The home NAT is read by the
	# `netcheck` verb, from the laptop at home.
	inner=$(ct 'runuser -u tailscaled -- tailscale netcheck --format=json' 2>/dev/null | python3 -I -c "$NC_FIELDS" 2>/dev/null)
	ok "the container's daemon user has no UDP out (D8)" UDP=False "${inner%% *}"
	rec "netcheck, the container's daemon user" "${inner:-no answer}"

	echo "== 5. every other port on pve1 is dropped by the policy, in the container"
	t0=$(pve 'date +%s' 2>/dev/null)
	ok "pve1's SSH through the tunnel" open "$(probe "$PVE" 22 10)"
	ok "pve1's web interface through the tunnel" open "$(probe "$PVE" 8006 10)"
	# Spaced: the container logs a drop at most every 5 s after a burst of 10.
	for p in $DENIED_PORTS; do
		ok "pve1 port $p, not granted" filtered "$(probe "$PVE" "$p" 3)"
		sleep 2
	done
	t_last=$(date +%s)
	# A port the policy let through is dialled by the container's daemon, and
	# the container's own filter drops that dial silently: it waits about two
	# minutes in SYN-SENT before "could not connect" is logged. So the dials
	# are read now, while they wait, and the log again in check 11, after.
	dialing=$(ct "ss -Htn state syn-sent dst $PVE; echo read-ok" 2>/dev/null)
	ok "the container's pending dials were read" yes "$(grep -qx read-ok <<<"$dialing" && echo yes || echo no)"
	ok "no denied port is being dialled from the container" "" "$(grep -vx read-ok <<<"$dialing" | awk '{print $4}' | sort -u | xargs)"
	for p in 111 123; do
		timeout 2 bash -c "echo x >/dev/udp/$PVE/$p" 2>/dev/null
		sleep 5
	done
	drops_before=$(ct 'nft list chain inet homelab output' 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\) .*comment "dropped".*/\1/p')
	if command -v ping >/dev/null; then
		ok "ping to pve1 through the tunnel (never answers, by design)" silent "$(ping -c 2 -W 3 "$PVE" >/dev/null 2>&1 && echo answered || echo silent)"
	fi
	drops_after=$(ct 'nft list chain inet homelab output' 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\) .*comment "dropped".*/\1/p')
	rec "the container's final drop counter, before and after the ping" "${drops_before:-?} -> ${drops_after:-?}"
	journal=$(ct "journalctl -u tailscaled --since @${t0:-0} --no-pager -o cat" 2>/dev/null)
	printf '%s\n' "$journal" >"$LOG/tailscaled.log"
	passed=$(grep -F 'could not connect to local backend server at 10.0.10.10:' <<<"$journal" | grep -oE '10\.0\.10\.10:[0-9]+' | sort -u | xargs)
	ok "no denied port reached pve1's side of the container" "" "$passed"
	esc=${LAPTOP_TS//./\\.}
	seen=""
	missing=""
	for p in $DENIED_PORTS; do
		if grep -qE "Drop: TCP\{$esc(:[0-9]+)? > 10\.0\.10\.10:$p\}" <<<"$journal"; then seen+="$p "; else missing+="$p "; fi
	done
	ok "the policy's drop is in the container's log" yes "$([ -n "$seen" ] && echo yes || echo "no ($LOG/tailscaled.log)")"
	rec "denied ports seen dropped in the log / not seen" "${seen:-none} / ${missing:-none}"
	rec "UDP drops logged" "$(grep -cE "Drop: UDP\{$esc(:[0-9]+)? > 10\.0\.10\.10:" <<<"$journal")"

	echo "== 6. a refused recipe is refused through the tunnel (the R.9 method)"
	ok "session length start would choose" "2 away" "$(bash scripts/ops/session.sh hours)"
	for p in pve pve-tokens pve-backup-init; do
		expect "$p, a real run with only the guard" refused "from '10.0.30.10'" play "$p" --tags away-guard
	done
	expect "pve, a dry run with only the guard" allowed '' play pve --check --tags away-guard
	# Harmless even with a broken guard: a plan file that does not exist, and
	# media without a key to render its answer file.
	expect "OpenTofu remote apply" refused "is not run through the away tunnel" tofu remote apply -input=false "$LOG/no-such.tfplan"
	expect "install media: validate" refused "install media is built and written at home" env SOPS_AGE_KEY_FILE=/nonexistent bash scripts/pve/build-install-media.sh validate

	echo "== 7. no other device at home reaches the container (from pve1, the management network)"
	# Zone mgmt has no rule into zone remote: the router resets every port.
	# "filtered" would be the router letting it through and the hypervisor's
	# guest filter dropping it.
	homeside=$(
		pve 'bash -s' 2>/dev/null <<'EOF'
for p in 22 53 80 443 8006 41641; do
	out=$(timeout 3 bash -c "exec 3<>/dev/tcp/10.0.30.10/$p" 2>&1); rc=$?
	case $rc in 0) r=open ;; 124) r=filtered ;; *) case "$out" in *refused*) r=refused ;; *) r=unreachable ;; esac ;; esac
	echo "$p $r"
done
EOF
	)
	for p in 22 53 80 443 8006 41641; do
		ok "pve1 to the container, port $p" refused "$(sed -n "s/^$p //p" <<<"$homeside")"
	done

	echo "== 8. packet size: segments fit the tunnel, and a copy goes through"
	pve 'sleep 8' >/dev/null 2>&1 &
	sleep 4
	mss=$(ss -Htin state established dst "$PVE" dport = :22 2>/dev/null | grep -oE '(^| )mss:[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -n 1)
	wait
	ok "the SSH connection's segment size, at most 1240" yes "$([ -n "$mss" ] && [ "$mss" -le 1240 ] && echo yes || echo "no (${mss:-not read})")"
	rec "ssh mss" "${mss:-not read}"
	# No time limit on the copies: a stall of a minute ends pve()'s
	# connection, and slow alone is not a failure (the plan's risk table).
	ok "1 MiB from pve1" 1048576 "$(pve 'dd if=/dev/zero bs=64k count=16 status=none' 2>/dev/null | wc -c)"

	echo "== 9. a full dry run of the hypervisor play, timed"
	s=$EPOCHREALTIME
	# Ansible's own options, one shared connection, plus pve()'s rule: a stall
	# of a minute ends the connection, the host becomes unreachable, and the
	# check fails.
	ANSIBLE_SSH_ARGS='-C -o ControlMaster=auto -o ControlPersist=60s -o ServerAliveInterval=10 -o ServerAliveCountMax=6' \
		bash scripts/ops/play.sh pve --check >"$LOG/dry-run.log" 2>&1 </dev/null
	rc=$?
	secs=$(python3 -I -c "print(round($EPOCHREALTIME - $s))")
	recap=$(grep -E '^pve1 +:' "$LOG/dry-run.log" | tail -n 1 | tr -s ' ')
	ok "the dry run ends cleanly" 0 "$rc"
	ok "no task failed, the host reached" yes "$(grep -q 'unreachable=0 failed=0' <<<"$recap" && echo yes || echo "no ($LOG/dry-run.log)")"
	rec "dry run (seconds, recap)" "$secs, ${recap#pve1 : }"

	echo "== 10. 100 MiB each way, timed"
	rate() { python3 -I -c "t = $EPOCHREALTIME - $1; print('%.0f s, %.2f MB/s' % (t, ${2:-0} / 1e6 / t))"; }
	s=$EPOCHREALTIME
	n=$(pve 'dd if=/dev/zero bs=1M count=100 status=none' 2>/dev/null | wc -c)
	pull=$(rate "$s" "$n")
	ok "100 MiB from pve1" 104857600 "$n"
	s=$EPOCHREALTIME
	n=$(dd if=/dev/zero bs=1M count=100 status=none | pve 'wc -c' 2>/dev/null | tr -d '[:space:]')
	push=$(rate "$s" "$n")
	ok "100 MiB to pve1" 104857600 "$n"
	rec "pull, push (R.8 at home: 117 s, 167 s)" "$pull; $push"

	echo "== 11. after the run"
	really_outside after
	# shellcheck disable=SC2016  # expanded in the container
	health=$(ct 'r=$(systemctl show -p Result --value remote-health.service); t=$(systemctl show -p ExecMainExitTimestamp --value remote-health.service); if [ -n "$t" ]; then echo "$r $(( $(date +%s) - $(date -d "$t" +%s) ))"; else echo "${r:-none} never"; fi' 2>/dev/null)
	ok "the last health report succeeded" success "${health%% *}"
	ok "and was made within the last 11 minutes" yes "$(
		a=${health##* }
		[[ $a =~ ^[0-9]+$ ]] && [ "$a" -le 660 ] && echo yes || echo "no (${health:-no answer})"
	)"
	# Every dial of check 5 has failed by now and logged it, if one was made.
	left=$((${t_last:-0} + 140 - $(date +%s)))
	if [ "$left" -gt 0 ]; then sleep "$left"; fi
	late=$(ct "journalctl -u tailscaled --since @${t0:-0} --no-pager -o cat; echo read-ok" 2>/dev/null)
	ok "the container's log was read again" yes "$(grep -qx read-ok <<<"$late" && echo yes || echo no)"
	ok "no denied port reached pve1's side of the container, read after 140 s" "" "$(grep -F 'could not connect to local backend server at 10.0.10.10:' <<<"$late" | grep -oE '10\.0\.10\.10:[0-9]+' | sort -u | xargs)"
	mem=$(bash scripts/ops/remote-memory.sh read 2>/dev/null | grep '^remote1-memory ' | tail -n 1)
	rec "remote1 memory (drill 5)" "${mem:-not read}"
}

# ---- netcheck: the home NAT, read at home before -Away ---------------------------------
home_netcheck() {
	echo "== the home network's NAT, read from the laptop at home (drill 4)"
	echo "R.10 home netcheck, $(date '+%Y-%m-%d %H:%M %Z')" >"$SUMMARY"
	f=$(win_facts)
	ok "this laptop is on the home network" yes "$([ -n "$(fact home "$f")" ] && echo yes || echo no)"
	rec "netcheck, this laptop at home (the home router and the provider's NAT)" "$(ts_json netcheck --format=json | python3 -I -c "$NC_FIELDS" 2>/dev/null)"
}

# ---- web: the owner's browser check ------------------------------------------------
web() {
	preconditions
	echo "== the web interface and a console through the tunnel"
	n=$(pve 'sudo awk "END { print NR }" /var/log/pveproxy/access.log' 2>/dev/null)
	cat <<'EOF'
In the laptop's browser, now:
  1. Open https://10.0.10.10:8006. The certificate prompt is the one you know from home.
  2. Log in with your administrator account: password and TOTP.
  3. pve1, Shell: a "login:" prompt (or a shell, for root@pam). Do not log in. Close it.
  4. CT 3010 (remote1), Console: a prompt. Type nothing (it carries this session). Close it.
  5. Not SPICE: its port is not granted.
  6. Log out (your user name, top right, Logout) and close every tab of the web interface:
     an open page asks pve1 every few seconds, and the phone check would count it.
EOF
	read -r -p "Press Enter when done ... " _
	# Lines from the container's address since the count above; the query
	# strings carry tickets and are cut off before anything is shown.
	# shellcheck disable=SC2029  # the count is expanded here
	new=$(pve "sudo awk -v n=${n:-0} 'NR > n' /var/log/pveproxy/access.log" 2>/dev/null | grep -E '^(::ffff:)?10\.0\.30\.10 - ' | sed -E 's/\?[^ "]*//')
	printf '%s\n' "$new" >"$LOG/access.log"
	ok "a login with the ticket call" yes "$(grep -qE '"POST /api2/[a-z]+/access/ticket ' <<<"$new" && echo yes || echo no)"
	ok "a console opened (termproxy or vncproxy)" yes "$(grep -qE '"POST /api2/[a-z]+/nodes/[^ ]*/(termproxy|vncproxy) ' <<<"$new" && echo yes || echo no)"
	ok "its websocket upgraded, on port 8006" yes "$(grep -qE '"GET /api2/[a-z]+/nodes/[^ ]*/vncwebsocket [^"]*" 101 ' <<<"$new" && echo yes || echo no)"
	rec "web interface lines from the container's address" "$(grep -c . <<<"$new")"
}

# ---- phone: the owner's phone check ------------------------------------------------
phone() {
	preconditions
	echo "== the phone reaches nothing"
	ok "the laptop's tunnel is up (it carries this test's reads)" Running "$(fact backend "$(the_client)")"
	before=$(pve 'date +%s; sudo awk "END { print NR }" /var/log/pveproxy/access.log' 2>/dev/null | xargs)
	t0=${before%% *}
	n=${before##* }
	cat <<EOF
First close every tab of pve1's web interface on the laptop (an open one is
counted against the phone), then touch nothing in the laptop's browser.
On the phone, now:
  1. Wi-Fi off, mobile data only; Tailscale connected. The hotspot may stay on if
     "Allow clients to use VPN" is off or absent.
  2. In the Tailscale app: note whether remote1 and the laptop are listed.
  3. In the browser, each must fail (a timeout or "can't be reached"; a page or a
     certificate warning is a FAIL):
       https://10.0.10.10:8006      https://10.0.10.10:443
       http://10.0.30.10:80         https://10.0.30.10:8006
       https://$REMOTE1_TS:8006   http://$REMOTE1_TS:80
       http://$LAPTOP_TS:8007       http://$LAPTOP_TS:445      http://$LAPTOP_TS:3389
  4. Disconnect Tailscale on the phone.
EOF
	read -r -p "Press Enter when done ... " _
	# One session for every read after the window: its own login is the only
	# one allowed in pve1's log.
	after=$(
		pve "bash -s -- $((t0 + 1)) $n $VMID $PHONE_TS" 2>/dev/null <<'EOF'
set -- "$1" "$2" "$3" "$4" $SSH_CONNECTION
since=$1 n=$2 vmid=$3 phone=$4 me=$6
j=$(sudo pct exec "$vmid" -- journalctl -u tailscaled --since "@$since" --no-pager -o cat)
echo "backend $(grep -cF 'could not connect to local backend server' <<<"$j")"
# A dial the policy let through waits about two minutes before it is logged:
# the ones still waiting are read here.
echo "dialing $(sudo pct exec "$vmid" -- ss -Htn state syn-sent '( dst 10.0.10.10 or dst 127.0.0.0/8 or dst 10.0.30.10 )' | grep -c .)"
echo "drops $(grep -F 'Drop: ' <<<"$j" | grep -F "{$phone" | grep -oE '> [0-9.]+:[0-9]+' | sort | uniq -c | xargs)"
# Query strings carry tickets: cut off before anything leaves pve1.
w=$(sudo awk -v n="$n" 'NR > n' /var/log/pveproxy/access.log | grep -E '^(::ffff:)?10\.0\.30\.10 - ' | sed -E 's/\?[^ "]*//')
echo "web $(grep -c . <<<"$w")"
sed 's/^/line /' <<<"$w" | grep -v '^line $'
echo "logins $(sudo journalctl -t sshd-session -t sshd -t sshd-auth --since "@$since" --no-pager -o cat | grep -F 'Accepted publickey for ' | grep -F 'from 10.0.30.10 ' | grep -vcF "port $me ssh2:")"
EOF
	)
	sed -n 's/^line //p' <<<"$after" >"$LOG/phone-access.log"
	ok "nothing reached pve1's side of the container" 0 "$(sed -n 's/^backend //p' <<<"$after")"
	ok "no dial from the container still waiting" 0 "$(sed -n 's/^dialing //p' <<<"$after")"
	webn=$(sed -n 's/^web //p' <<<"$after")
	ok "no web interface request from the container's address" 0 "$(if [ "${webn:-x}" = 0 ]; then echo 0; else echo "${webn:-not read} (see $LOG/phone-access.log: a user name other than '-' is a logged-in browser, the laptop's)"; fi)"
	ok "no other SSH login through the container" 0 "$(sed -n 's/^logins //p' <<<"$after")"
	rec "the phone's packets dropped in the container (count, destination)" "$(sed -n 's/^drops //p' <<<"$after")"
	echo "  For the laptop's side, in an elevated PowerShell:"
	printf '%s\n' "    Select-String -Path C:\\ProgramData\\Tailscale\\Logs\\tailscale-service-*.txt -Pattern 'Drop: TCP\\{$PHONE_TS' | Select-Object -Last 20"
}

# ---- end: the session takes the tunnel with it ---------------------------------------
end_session() {
	echo "== the away session ends, and the tunnel with it"
	bash scripts/ops/session.sh end
	c=$(the_client)
	ok "the Windows client after the session ended" Stopped "$(fact backend "$c")"
	ok "routes accepted after the session ended" False "$(fact prefs "$c" | awk '{print $2}')"
	f=$(win_facts)
	ok "pve1 is not routed through the tunnel" yes "$([ "$(fact pve1 "$f")" != Tailscale ] && echo yes || echo no)"
	if [ -z "$(fact home "$f")" ]; then
		ok "from the road, nothing leads home without the tunnel" yes "$(case "$(probe "$PVE" 22 5)" in filtered | unreachable) echo yes ;; *) echo no ;; esac)"
	else
		echo "  (at home: the probe of pve1 without the tunnel is skipped)"
	fi
}

case "$VERB" in
run) run_all ;;
netcheck) home_netcheck ;;
web) web ;;
phone) phone ;;
end) end_session ;;
*)
	echo "usage: $0 [netcheck|web|phone|end]" >&2
	exit 2
	;;
esac

echo
if [ "$fail" -eq 0 ]; then
	echo "outside test ($VERB) as designed: $checks checks, all as expected." | tee -a "$SUMMARY"
else
	echo "OUTSIDE TEST ($VERB) DIFFERS: $fail of $checks checks disagree." | tee -a "$SUMMARY"
	exit 1
fi
