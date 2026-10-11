#!/bin/bash
# Read-back of the router's two remote-access zones (Phase R, step R.5;
# docs/ARCHITECTURE.md section 6, E15 to E17). Read-only: it reads the
# router's state over SSH and opens a few TCP connections from WSL.
#
#   scripts/tests/router-remote-zones.sh      (or: just test-router-zones)
#
# Runs in WSL with a session open, at home. The guarded apply confirms a
# change when the internet and name lookups work; none of its checks looks
# at what this step adds, so this script is the gate. It exits non-zero when
# one line disagrees.
#
# No host lives in VLAN 30 before step R.7. Until then the probes prove
# which rule a packet meets (the counter of E17 moves, the others are
# refused), not that anything is delivered.
set -uo pipefail

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
ROUTER=192.168.1.53
PVE=10.0.10.10
REMOTE1=10.0.30.10

fail=0
checks=0
ok() { # <what> <expected> <got>
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		printf '  ok    %-58s %s\n' "$1" "$3"
	else
		printf '  FAIL  %-58s %s (expected %s)\n' "$1" "$3" "$2"
		fail=$((fail + 1))
	fi
}

# shellcheck disable=SC2029  # the command is expanded here on purpose
router() { ssh "${SSH_OPTS[@]}" "root@$ROUTER" "$@" 2>/dev/null; }

if ! state=$(
	router sh -s <<'EOF'
echo "armed=$(ls /tmp/homelab-rollback/armed.* 2>/dev/null | wc -l)"
for v in 30 31; do
	d=br-lan.$v
	echo "addr$v=$(ip -4 -o addr show dev $d 2>/dev/null | awk '{print $4}' | tr '\n' ' ' | sed 's/ $//')"
	echo "noipv6_$v=$(cat /proc/sys/net/ipv6/conf/$d/disable_ipv6 2>/dev/null)"
	echo "v6addr$v=$(ip -6 -o addr show dev $d 2>/dev/null | wc -l)"
	echo "v6route$v=$(ip -6 route show dev $d 2>/dev/null | wc -l)"
	# every port that carries the VLAN, as "port:tagged" or "port:<flags>"
	echo "ports$v=$(bridge vlan show 2>/dev/null | awk -v v="$v" 'NR > 1 && NF {
		if ($0 ~ /^[^ \t]/) { port = $1; id = $2; fl = $3 $4 $5 } else { id = $1; fl = $2 $3 $4 }
		if (id == v) print port ":" (fl == "" ? "tagged" : fl)
	}' | sort | tr '\n' ' ' | sed 's/ $//')"
done
echo "ra=$(uci -q show dhcp | grep -c -E "^dhcp\.(remote|home_remote)\.(ra|dhcpv6|dhcpv4)=")"
echo "ignore=$(uci -q get dhcp.remote.ignore)$(uci -q get dhcp.home_remote.ignore)"
nft list chain inet fw4 input >/tmp/hl-rz.input 2>/dev/null
nft list chain inet fw4 forward >/tmp/hl-rz.forward 2>/dev/null
echo "jump_in_remote=$(grep -c 'iifname "br-lan.30" jump input_remote' /tmp/hl-rz.input)"
echo "jump_in_home=$(grep -c 'iifname "br-lan.31" jump input_home_remote' /tmp/hl-rz.input)"
echo "jump_fw_remote=$(grep -c 'iifname "br-lan.30" jump forward_remote' /tmp/hl-rz.forward)"
echo "jump_fw_home=$(grep -c 'iifname "br-lan.31" jump forward_home_remote' /tmp/hl-rz.forward)"
rm -f /tmp/hl-rz.input /tmp/hl-rz.forward
# Accepting lines of each zone chain, without counters, one per line.
for c in input_remote forward_remote input_home_remote forward_home_remote; do
	nft list chain inet fw4 "$c" 2>/dev/null | grep -E 'accept|jump accept_to' | sed -e 's/counter packets [0-9]* bytes [0-9]* //' -e 's/^[[:space:]]*//' | sed "s/^/rule:$c:/"
done
echo "e17=$(nft list chain inet fw4 forward_lan 2>/dev/null | grep 'E17-workstation-to-remote1-ssh' | sed -n 's/.*counter packets \([0-9]*\).*/\1/p')"
echo "names=$(uci -q show firewall | grep -c -E "\.name='(Router-DNS-remote|E15-remote1-to-pve1|E16-remote1-to-wan-https|E17-workstation-to-remote1-ssh)'")"
echo "home_in_rules=$(uci -q show firewall | grep -E "\.(src|dest)='home_remote'" | wc -l)"
# Rule files that the firewall loads besides the managed configuration:
# every line in them that is not a comment.
echo "nftd=$(cat /etc/nftables.d/*.nft 2>/dev/null | grep -c -v -E '^[[:space:]]*(#|$)')"
EOF
); then
	echo "the router is not reachable over ssh"
	exit 1
fi
get() { sed -n "s/^$1=//p" <<<"$state" | head -n 1; }

echo "== no change waits for its confirmation"
ok "armed revert flags" 0 "$(get armed)"

echo "== VLAN 30, zone remote"
ok "router address on br-lan.30" "10.0.30.1/24" "$(get addr30)"
ok "ports that carry VLAN 30" "br-lan:tagged lan1:tagged" "$(get ports30)"
ok "IPv6 switched off on br-lan.30" 1 "$(get noipv6_30)"
ok "IPv6 addresses on br-lan.30" 0 "$(get v6addr30)"
ok "IPv6 routes on br-lan.30" 0 "$(get v6route30)"
ok "input from br-lan.30 goes to the zone's chain" 1 "$(get jump_in_remote)"
ok "forward from br-lan.30 goes to the zone's chain" 1 "$(get jump_fw_remote)"

echo "== VLAN 31, zone home_remote"
ok "router address on br-lan.31" "10.0.31.1/24" "$(get addr31)"
ok "ports that carry VLAN 31" "br-lan:tagged lan1:tagged" "$(get ports31)"
ok "IPv6 switched off on br-lan.31" 1 "$(get noipv6_31)"
ok "IPv6 addresses on br-lan.31" 0 "$(get v6addr31)"
ok "IPv6 routes on br-lan.31" 0 "$(get v6route31)"
ok "input from br-lan.31 goes to the zone's chain" 1 "$(get jump_in_home)"
ok "forward from br-lan.31 goes to the zone's chain" 1 "$(get jump_fw_home)"
ok "rules that name the zone home_remote" 0 "$(get home_in_rules)"
ok "accepting lines in its two chains" 0 "$(grep -c -E '^rule:(input|forward)_home_remote:' <<<"$state")"

echo "== no DHCP, no advertisements"
ok "both DHCP sections ignored" 11 "$(get ignore)"
ok "advertisement or DHCPv6 options on the two networks" 0 "$(get ra)"

echo "== the rules of the zone remote, as loaded"
ok "the four rules exist in the configuration" 4 "$(get names)"
ok "active lines in rule files outside the managed configuration" 0 "$(get nftd)"
ok "accepting lines for input from the zone" 2 "$(grep -c '^rule:input_remote:' <<<"$state")"
ok "accepting lines for forwarding from the zone" 2 "$(grep -c '^rule:forward_remote:' <<<"$state")"
ok "every accepting line names the container's address" 0 "$(grep -E '^rule:(input|forward)_remote:' <<<"$state" | grep -c -v "ip saddr $REMOTE1 ")"
grep -E '^rule:(input|forward)_remote:' <<<"$state" | sed 's/^rule:/        /'

echo "== from WSL (the workstation's address)"
probe() {
	local out rc
	out=$(timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
	rc=$?
	case $rc in 0) echo open ;; 124) echo filtered ;; *) case "$out" in *refused*) echo refused ;; *) echo unreachable ;; esac ;; esac
}
before=$(get e17)
probe "$REMOTE1" 22 >/dev/null
after=$(router "nft list chain inet fw4 forward_lan" | grep 'E17-workstation-to-remote1-ssh' | sed -n 's/.*counter packets \([0-9]*\).*/\1/p')
if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then moved=yes; else moved=no; fi
ok "a connection to $REMOTE1:22 meets E17 (its counter moves)" yes "$moved"
# Another port of the container, another address in its network, and the
# household network of VLAN 31. (The router's own addresses in the two
# networks are not probed: for the workstation they are the router, E1.)
for t in "$REMOTE1 8006" "10.0.30.11 22" "10.0.31.10 22" "10.0.31.10 443"; do
	# shellcheck disable=SC2086  # host and port are two words on purpose
	got=$(probe $t)
	case "$got" in refused | filtered | unreachable) got=closed ;; esac
	ok "nothing answers on ${t/ /:}" closed "$got"
done

echo "== the trunk to the hypervisor still carries the management network"
ok "the hypervisor's SSH port from the workstation" open "$(probe "$PVE" 22)"
ok "the hypervisor's web interface from the workstation" open "$(probe "$PVE" 8006)"

echo
if [ "$fail" -eq 0 ]; then
	echo "remote zones as designed: $checks checks, all as expected"
else
	echo "REMOTE ZONES DIFFER: $fail of $checks checks disagree"
	exit 1
fi
