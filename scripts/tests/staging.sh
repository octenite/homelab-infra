#!/bin/bash
# The staging machine read back and probed from inside (read-only): the
# fences around a machine whose users are not the household's (ADR 0007).
#
#   staging.sh        (or: just test-staging)
#
# Three parts: what the hypervisor stores for guest 4010, what its firewall
# holds for the guest's network device, and what the machine itself can
# reach. The third is the one that counts: every address at home must stay
# closed from inside, whatever runs there. Needs an operator session at home;
# the machine must be running.
set -euo pipefail

VMID=4010
ADDR=10.0.40.10
ROUTER=10.0.40.1
HOST=10.0.10.10
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
PVE=(ssh -o BatchMode=yes -o ConnectTimeout=8 "ops@$HOST")
VM=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=stg1 "ops@$ADDR")

checks=0
fail=0
ok() { # <what> <expected> <got>
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		printf '  ok    %-62s %s\n' "$1" "$3"
	else
		printf '  FAIL  %-62s %s (expected %s)\n' "$1" "${3:-(nothing)}" "$2"
		fail=$((fail + 1))
	fi
}

echo "== the machine as the hypervisor stores it"
facts=$(
	"${PVE[@]}" sudo sh -s <<EOF
conf=\$(qm config $VMID 2>/dev/null) || { echo "exists=no"; exit 0; }
echo "exists=yes"
echo "status=\$(qm status $VMID | cut -d' ' -f2)"
echo "net0=\$(printf '%s\n' "\$conf" | sed -n 's/^net0: //p' | sed 's/virtio=[0-9A-Fa-f:]*,//')"
echo "nets=\$(printf '%s\n' "\$conf" | grep -c '^net[0-9]*:')"
echo "protection=\$(printf '%s\n' "\$conf" | sed -n 's/^protection: //p')"
echo "ip=\$(printf '%s\n' "\$conf" | sed -n 's/^ipconfig0: //p')"
echo "pool=\$(pvesh get /pools/staging --output-format json | grep -c '"vmid":$VMID')"
echo "passthrough=\$(printf '%s\n' "\$conf" | grep -cE '^(hostpci|usb|mp|virtiofs)[0-9]*:' || true)"
echo "file=\$([ -s /etc/pve/firewall/$VMID.fw ] && echo present || echo missing)"
opts=\$(pvesh get /nodes/pve1/qemu/$VMID/firewall/options --output-format json)
for k in enable ipfilter macfilter dhcp ndp radv policy_in policy_out layer2_protocols; do
	echo "fw_\$k=\$(printf '%s' "\$opts" | python3 -c "import json, sys; print(json.load(sys.stdin).get('\$k', ''))")"
done
rules=\$(pvesh get /nodes/pve1/qemu/$VMID/firewall/rules --output-format json)
echo "rules_in=\$(printf '%s' "\$rules" | python3 -c "import json, sys; print(sum(1 for r in json.load(sys.stdin) if r['type'] == 'in'))")"
echo "rules_in_ssh=\$(printf '%s' "\$rules" | python3 -c "import json, sys; print(sum(1 for r in json.load(sys.stdin) if r['type'] == 'in' and r.get('dport') == '22' and r.get('dest') == '$ADDR' and r.get('source', '') != ''))")"
echo "rules_out_any=\$(printf '%s' "\$rules" | python3 -c "import json, sys; print(sum(1 for r in json.load(sys.stdin) if r['type'] == 'out' and r.get('dest', '') == ''))")"
echo "rules_not_accept=\$(printf '%s' "\$rules" | python3 -c "import json, sys; print(sum(1 for r in json.load(sys.stdin) if r['action'] != 'ACCEPT'))")"
echo "compile=\$(pve-firewall compile 2>&1 >/dev/null | wc -l)"
echo "daemon=\$(pve-firewall status | head -n 1)"
EOF
)
f() { sed -n "s/^$1=//p" <<<"$facts" | head -n 1; }
ok "guest $VMID exists" yes "$(f exists)"
if [ "$(f exists)" != yes ]; then
	echo
	echo "STAGING DIFFERS: the machine is not there"
	exit 1
fi
ok "one network device" 1 "$(f nets)"
ok "the device: bridge, firewall flag, VLAN tag" "bridge=vmbr0,firewall=1,tag=40" "$(f net0)"
ok "its address and gateway" "gw=$ROUTER,ip=$ADDR/24" "$(f ip)"
ok "in pool staging" 1 "$(f pool)"
ok "protected against deletion" 1 "$(f protection)"
ok "no device or directory of the host passed in" 0 "$(f passthrough)"

echo "== the hypervisor's filter for its network device"
ok "the firewall file" present "$(f file)"
ok "filter switched on" 1 "$(f fw_enable)"
ok "inbound policy" DROP "$(f fw_policy_in)"
ok "outbound policy" DROP "$(f fw_policy_out)"
ok "may send from its one address only" 1 "$(f fw_ipfilter)"
ok "may send from its one hardware address only" 1 "$(f fw_macfilter)"
ok "ARP is the only other frame type" ARP "$(f fw_layer2_protocols)"
ok "no DHCP, no IPv6 neighbour or router messages" "0 0 0" "$(f fw_dhcp) $(f fw_ndp) $(f fw_radv)"
ok "one inbound rule" 1 "$(f rules_in)"
ok "and it is SSH from named sources" 1 "$(f rules_in_ssh)"
ok "no outbound rule without a destination" 0 "$(f rules_out_any)"
ok "every rule is an ACCEPT under the DROP policies" 0 "$(f rules_not_accept)"
ok "the firewall files compile without a word" 0 "$(f compile)"
ok "the firewall daemon" "Status: enabled/running" "$(f daemon)"

echo "== what the machine reaches, probed from inside"
ok "the machine runs" running "$(f status)"
if [ "$(f status)" != running ]; then
	echo
	echo "STAGING DIFFERS: the machine is not running, so nothing was probed from inside"
	exit 1
fi
probes=$(
	"${VM[@]}" bash -s <<'EOF'
probe() {
	local o rc r
	o=$(timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1)
	rc=$?
	case $rc in 0) r=open ;; 124) r=filtered ;; *) case "$o" in *refused*) r=refused ;; *nreachable* | *"No route"*) r=unreachable ;; *) r=error ;; esac ;; esac
	echo "tcp $1 $2 $r"
}
# What the zone allows.
probe deb.debian.org 443
probe github.com 22
probe github.com 443
probe region1.v2.argotunnel.com 7844
# The router itself, beyond the resolver and the clock.
for p in 22 80 443; do probe 10.0.40.1 $p; done
# Everything at home: the hypervisor, the management network, the household's
# networks, the router's other addresses, the backup server's forward.
for t in "10.0.10.10 22" "10.0.10.10 8006" "10.0.10.10 9100" "10.0.10.1 22" "10.0.10.1 443" "10.0.10.2 22" "10.0.10.3 22" \
	"192.168.1.53 22" "192.168.1.53 443" "192.168.1.1 80" "192.168.1.196 8007" "192.168.1.196 3389" "192.168.1.197 22" \
	"10.0.30.1 22" "10.0.30.10 22" "10.0.31.1 53" "10.0.50.1 22" "10.0.60.1 53" "10.0.99.1 22"; do
	probe $t
done
# The internet on a port the zone does not name.
probe 1.1.1.1 53
probe 1.1.1.1 8080
getent hosts deb.debian.org >/dev/null && echo "dns router ok" || echo "dns router fail"
timeout 4 bash -c 'exec 3<>/dev/udp/1.1.1.1/53; printf "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01" >&3; head -c 1 <&3 | wc -c' 2>/dev/null | grep -qx 1 && echo "dns outside answered" || echo "dns outside silent"
ip -6 addr show scope global | grep -q inet6 && echo "ipv6 global yes" || echo "ipv6 global no"
EOF
)
p() { sed -n "s/^tcp $1 $2 //p" <<<"$probes" | head -n 1; }
closed() { case "$(p "$1" "$2")" in filtered | unreachable | refused) echo closed ;; *) p "$1" "$2" ;; esac }
ok "Debian's mirrors over HTTPS" open "$(p deb.debian.org 443)"
ok "GitHub over SSH" open "$(p github.com 22)"
ok "GitHub over HTTPS" open "$(p github.com 443)"
ok "Cloudflare's tunnel port" open "$(p region1.v2.argotunnel.com 7844)"
ok "name lookups at the router" "dns router ok" "$(grep '^dns router' <<<"$probes")"
ok "no name lookups past the router" "dns outside silent" "$(grep '^dns outside' <<<"$probes")"
ok "no global IPv6 address" "ipv6 global no" "$(grep '^ipv6' <<<"$probes")"
for port in 22 80 443; do ok "the router's own port $port" closed "$(closed $ROUTER $port)"; done
while read -r host port what; do
	ok "$what ($host:$port)" closed "$(closed "$host" "$port")"
done <<'EOF'
10.0.10.10 22 the hypervisor's SSH
10.0.10.10 8006 the hypervisor's web interface
10.0.10.10 9100 the hypervisor's metrics
10.0.10.1 22 the router in the management network
10.0.10.1 443 the router's web interface there
10.0.10.2 22 access point 1
10.0.10.3 22 access point 2
192.168.1.53 22 the router in the home network
192.168.1.53 443 the router's web interface there
192.168.1.1 80 the home network's first address
192.168.1.196 8007 the backup server's forward on the workstation
192.168.1.196 3389 the workstation's remote desktop
192.168.1.197 22 the workstation's other address
10.0.30.1 22 the router in the remote-access network
10.0.30.10 22 the administration container
10.0.31.1 53 the household remote network
10.0.50.1 22 the servers network
10.0.60.1 53 the devices network
10.0.99.1 22 the hypervisor on the direct link
1.1.1.1 53 the internet on a port the zone does not name
1.1.1.1 8080 the internet on another such port
EOF

echo
if [ "$fail" -eq 0 ]; then
	echo "staging fences hold: $checks checks, all as expected"
else
	echo "STAGING DIFFERS: $fail of $checks checks failed"
	exit 1
fi
