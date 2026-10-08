#!/bin/bash
# Deny test of the backup path's fences (ARCHITECTURE.md E10, E14, X10 and
# docs/components/pbs.md "Fences"). Read-only: it only opens and closes TCP
# connections and sends pings, from every vantage point the lab offers.
#
#   scripts/tests/backup-fences.sh            (or: just test-fences)
#   scripts/tests/backup-fences.sh away       after pbs-vm.ps1 -Away: the
#                                             backup port answers nobody
#
# Runs in WSL with a session open. Vantage points: the hypervisor, the router
# (a trusted-network source that no rule admits), WSL itself, and the backup
# server (only while the management window is open: pbs-vm.ps1 -Manage).
# Every line states what was expected; the script exits non-zero when a
# single probe disagrees.
#
# Results: open (connection accepted), refused (reset or ICMP came back),
# filtered (no answer). "closed" in an expectation accepts refused or
# filtered: both mean nothing answered on that port.
set -uo pipefail

case "${1:-home}" in
home) FORWARD=open ;;
away) FORWARD=closed ;;
*)
	echo "usage: $0 [away]" >&2
	exit 2
	;;
esac

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
PVE=10.0.10.10
ROUTER=192.168.1.53
P2P_PVE=10.0.99.1
P2P_HOST=10.0.99.2
P2P_PBS=10.0.99.3
NAT_HOST=10.0.98.1
WS_ADDRS=(192.168.1.196 192.168.1.197)
GW=$(ip -4 route show default | awk '{print $3; exit}')

fail=0
checks=0
check() { # <from> <target> <port> <expected> <got>
	checks=$((checks + 1))
	local ok=no
	case "$4:$5" in
	open:open | filtered:filtered | refused:refused | closed:filtered | closed:refused | closed:unreachable | answered:answered | silent:silent) ok=yes ;;
	esac
	if [ "$ok" = yes ]; then
		printf '  ok    %-12s -> %-16s %-5s %-9s\n' "$1" "$2" "$3" "$5"
	else
		printf '  FAIL  %-12s -> %-16s %-5s %-9s expected %s\n' "$1" "$2" "$3" "$5" "$4"
		fail=$((fail + 1))
	fi
}

# The probe that runs on a Linux host; prints "<target> <port> <result>".
read -r -d '' PROBE <<'EOF' || true
probe() {
	out=$(timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1); rc=$?
	case $rc in
	0) r=open ;;
	124) r=filtered ;;
	*) case "$out" in *refused*) r=refused ;; *nreachable* | *"No route"*) r=unreachable ;; *) r=error ;; esac ;;
	esac
	echo "$1 $2 $r"
}
pingt() { if ping -c 2 -W 1 "$1" >/dev/null 2>&1; then echo "$1 ping answered"; else echo "$1 ping silent"; fi; }
EOF

run_on() { # <label> <"target port expected" lines> <ssh target...> ; runs the probes remotely, checks each
	local label=$1 spec=$2
	shift 2
	local cmds="" line
	while read -r t p _; do
		[ -n "$t" ] || continue
		if [ "$p" = ping ]; then cmds+="pingt $t"$'\n'; else cmds+="probe $t $p"$'\n'; fi
	done <<<"$spec"
	local out
	if ! out=$(ssh "${SSH_OPTS[@]}" "$@" 'bash -s' <<<"$PROBE"$'\n'"$cmds" 2>/dev/null); then
		echo "  SKIP  $label: not reachable over ssh"
		return 1
	fi
	while read -r t p exp; do
		[ -n "$t" ] || continue
		line=$(grep -m1 "^$t $p " <<<"$out" || true)
		check "$label" "$t" "$p" "$exp" "${line##* }"
	done <<<"$spec"
}

echo "== from the hypervisor"
# Over the direct link the workstation answers nothing and the backup server
# answers the backup port only. Over the home network the workstation answers
# the backup port (E14) and nothing else; after pbs-vm.ps1 -Away not even that.
echo "  backup port on the home network: expected $FORWARD"
spec=$(
	for p in 22 135 445 2222 3389 8007; do echo "$P2P_HOST $p filtered"; done
	echo "$P2P_HOST ping silent"
	echo "$P2P_PBS 8007 open"
	for p in 22 80 111; do echo "$P2P_PBS $p filtered"; done
	echo "$P2P_PBS ping answered"
)
run_on hypervisor "$spec" "ops@$PVE" || fail=$((fail + 1))

# Which of its two addresses does the workstation hold right now? (Windows side, read-only.)
held=$(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred | Where-Object IPAddress -like '192.168.1.*').IPAddress" 2>/dev/null | tr -d '\r')
# Without one of them the home-network probes below have no target, and a
# test that skipped them must not report that the fences hold.
held_count=0
for a in "${WS_ADDRS[@]}"; do
	if grep -qx "$a" <<<"$held"; then held_count=$((held_count + 1)); fi
done
if [ "$held_count" -eq 0 ]; then
	echo "  FAIL  the workstation holds none of ${WS_ADDRS[*]} (or Windows could not be asked): the home-network probes cannot run"
	fail=$((fail + 1))
fi
spec=$(
	for a in "${WS_ADDRS[@]}"; do
		if grep -qx "$a" <<<"$held"; then
			echo "$a 8007 $FORWARD"
			for p in 22 445 2222 3389; do echo "$a $p closed"; done
		fi
	done
)
run_on hypervisor "$spec" "ops@$PVE" || fail=$((fail + 1))

echo "== from the router (a trusted-network address that no rule admits)"
# dbclient is the only reliable TCP client on the devices; a watchdog replaces
# the missing timeout applet.
router_probe() { # <host> <port> -> answered | silent
	# shellcheck disable=SC2029  # host and port are expanded here on purpose
	ssh "${SSH_OPTS[@]}" "root@$ROUTER" sh -s -- "$1" "$2" <<'EOF' 2>/dev/null
f=/tmp/hl-probe.$$
(dbclient -y -y -i /nonexistent -p "$2" "root@$1" true >"$f" 2>&1) &
pid=$!
i=0
while [ $i -lt 6 ] && kill -0 $pid 2>/dev/null; do
	sleep 1
	i=$((i + 1))
done
if kill -0 $pid 2>/dev/null; then
	kill $pid 2>/dev/null
	echo silent
elif grep -qiE 'timed out|refused|unreachable|no route' "$f"; then
	echo silent
else
	echo answered
fi
rm -f "$f"
EOF
}
for a in "${WS_ADDRS[@]}"; do
	grep -qx "$a" <<<"$held" || continue
	for p in 8007 2222; do
		got=$(router_probe "$a" "$p")
		check router "$a" "$p" silent "${got:-error}"
	done
done

echo "== from WSL (the operator's environment; not the hypervisor's address)"
window=closed
if timeout 3 bash -c "exec 3<>/dev/tcp/$GW/2222" 2>/dev/null; then window=open; fi
echo "  management window: $window"
wsl_probe() {
	local out rc
	out=$(timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
	rc=$?
	case $rc in 0) echo open ;; 124) echo filtered ;; *) case "$out" in *refused*) echo refused ;; *) echo unreachable ;; esac ;; esac
}
for a in "${WS_ADDRS[@]}"; do
	grep -qx "$a" <<<"$held" || continue
	check wsl "$a" 8007 closed "$(wsl_probe "$a" 8007)"
done
check wsl "$GW" 8007 closed "$(wsl_probe "$GW" 8007)"
check wsl "$P2P_HOST" 8007 closed "$(wsl_probe "$P2P_HOST" 8007)"

echo "== from the backup server"
if [ "$window" = open ]; then
	spec=$(
		# towards the hypervisor on the direct link: nothing answers
		for p in 22 123 3128 8006 9100 9633; do echo "$P2P_PVE $p filtered"; done
		echo "$P2P_PVE ping silent"
		# towards the workstation: the direct link and the NAT switch answer nothing
		for p in 445 2222 8007; do echo "$P2P_HOST $p closed"; done
		for p in 135 445 2179 2222 3389 8007; do echo "$NAT_HOST $p filtered"; done
		echo "$NAT_HOST ping silent"
		# towards the lab through the NAT leg: the port ACL drops every private range
		echo "$PVE 22 filtered"
		echo "$PVE 8006 filtered"
		echo "10.0.10.1 22 filtered"
		echo "10.0.10.2 22 filtered"
		echo "$ROUTER 22 filtered"
		echo "$ROUTER 443 filtered"
		echo "10.0.50.200 443 filtered"
		echo "${WS_ADDRS[0]} 445 filtered"
		echo "${WS_ADDRS[0]} 8007 filtered"
		echo "$ROUTER ping silent"
		# nor a Tailscale address: the resolver every Tailscale client offers
		echo "100.100.100.100 53 filtered"
		# and it keeps its way out
		echo "9.9.9.9 53 open"
		echo "download.proxmox.com 443 open"
	)
	run_on backup-vm "$spec" -o HostKeyAlias=pbs1 -p 2222 "ops@$GW" || fail=$((fail + 1))
else
	echo "  SKIP  the management window is closed; open it with pbs-vm.ps1 -Manage to include these probes"
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "fences hold: $checks probes, all as expected"
else
	echo "FENCES BROKEN: $fail of $checks probes disagree"
	exit 1
fi
