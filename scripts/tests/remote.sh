#!/bin/bash
# The administration container of Phase R, read back and probed (step R.7;
# docs/phases/phase-r-plan.md, docs/ARCHITECTURE.md section 6, E15 to E17).
#
#   scripts/tests/remote.sh             (or: just test-remote)
#   scripts/tests/remote.sh layers      also switches the hypervisor's filter
#                                       for the container off and on again,
#                                       to show which layer refuses what
#
# Runs at home, in WSL, with a session open. Read-only, with three exceptions:
# inside the container it adds a second address for one probe and removes it
# again; the "layers" form switches the guest firewall off for the time of
# one round of probes (through the API, with the OpenTofu token, which is
# exactly the right a thief of that token would have) and on again, with a
# timer on the hypervisor that switches it on if this script dies; and that
# API write leaves the firewall file in Proxmox's own layout, which the next
# `just pve-apply` puts back.
#
# With the container stopped, the read-back runs alone: the container is
# created stopped and is checked before its first start. In the "layers"
# form a stopped container is a failure.
#
# What the probes do not show: frames that the container tags itself with a
# VLAN (see the firewall template of the hypervisor play), UDP and ICMP.
# Those rest on the stored rules, which are compared field by field.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
MODE=${1:-plain}
case "$MODE" in plain | layers) ;; *)
	echo "usage: $0 [layers]" >&2
	exit 2
	;;
esac
HOST=10.0.10.10
NODE=pve1
VMID=3010
ADDR=10.0.30.10
ROUTER30=10.0.30.1
WORKSTATIONS=192.168.1.196,192.168.1.197
TOKEN_ID='terraform@pve!tofu'
CA="$REPO/private/proxmox/pve1-ca.crt"
TOKENS="$REPO/private/proxmox/tokens.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/dev/shm/homelab-session/age.key}"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
# The container's host key changes with every rebuild; its own entry, under
# a name, keeps a changed key from being mistaken for another host's.
CT_SSH=(ssh "${SSH_OPTS[@]}" -o HostKeyAlias=remote1 -o StrictHostKeyChecking=accept-new "root@$ADDR")

[ -r "$SOPS_AGE_KEY_FILE" ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}
secret=$(sops decrypt --extract "[\"$TOKEN_ID\"][\"secret\"]" "$TOKENS") || exit 1

fail=0
checks=0
ok() { # <what> <expected> <got>
	checks=$((checks + 1))
	if [ "$2" = "$3" ]; then
		printf '  ok    %-62s %s\n' "$1" "$3"
	else
		printf '  FAIL  %-62s %s (expected %s)\n' "$1" "${3:-(nothing)}" "$2"
		fail=$((fail + 1))
	fi
}
api() { # <METHOD> <path> [curl arguments] -> body
	local method=$1 path=$2
	shift 2
	printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$TOKEN_ID" "$secret" |
		curl --config - --silent --cacert "$CA" --max-time 20 --request "$method" "$@" "https://$HOST:8006/api2/json$path"
}
js() { python3 -c "import json, sys
d = json.load(sys.stdin).get('data')
$1" 2>/dev/null; }
host() { ssh "${SSH_OPTS[@]}" "ops@$HOST" sudo sh -s; }

echo "== the container as the hypervisor stores it (read with the OpenTofu token)"
conf=$(api GET "/nodes/$NODE/lxc/$VMID/config")
# An error answer has no data; every "absent" check below would then pass.
if [ "$(js "print('yes' if d else 'no')" <<<"$conf")" != yes ]; then
	echo "  FAIL  the stored configuration of guest $VMID could not be read: ${conf:0:160}"
	echo
	echo "REMOTE1 DIFFERS: the container is not there, or the token may not read it"
	exit 1
fi
get() { js "print(d.get('$1', ''))" <<<"$conf"; }
net0=$(get net0)
# The root says whether nesting is on; the stored value must be exactly that.
want_features=$(grep -q -E '^[[:space:]]*nesting[[:space:]]*=[[:space:]]*true' "$REPO/infrastructure/opentofu/roots/remote/main.tf" && echo nesting=1 || echo "")
ok "unprivileged" 1 "$(get unprivileged)"
ok "protected against deletion" 1 "$(get protection)"
ok "not started at boot" 0 "$(get onboot | sed 's/^$/0/')"
ok "features as the OpenTofu root says" "$want_features" "$(get features)"
ok "no tags" "" "$(get tags)"
ok "host name" remote1 "$(get hostname)"
ok "name server" "$ROUTER30" "$(get nameserver)"
ok "exactly one network device" 1 "$(js "print(len([k for k in d if k.startswith('net')]))" <<<"$conf")"
for want in bridge=vmbr0 tag=30 firewall=1 "ip=$ADDR/24" "gw=$ROUTER30"; do
	ok "net0 has $want" yes "$(grep -q -i -E "(^|,)$want(,|\$)" <<<"$net0" && echo yes || echo no)"
done
ok "net0 has no trunk VLANs" no "$(grep -q 'trunks=' <<<"$net0" && echo yes || echo no)"
ok "net0 has no IPv6 address configured" no "$(grep -q 'ip6=' <<<"$net0" && echo yes || echo no)"
res=$(api GET "/cluster/resources?type=vm")
ok "pool" remote "$(js "print(next((r.get('pool', '') for r in d if r.get('vmid') == $VMID), ''))" <<<"$res")"
ok "guests in the pool remote" 1 "$(js "print(len([r for r in d if r.get('pool') == 'remote']))" <<<"$res")"

echo "== the hypervisor's firewall for its network device, as stored"
opts=$(api GET "/nodes/$NODE/lxc/$VMID/firewall/options")
for o in enable=1 policy_in=DROP policy_out=DROP ipfilter=1 macfilter=1 dhcp=0 ndp=0 radv=0; do
	ok "option ${o%%=*}" "${o#*=}" "$(js "print(d.get('${o%%=*}', ''))" <<<"$opts")"
done
rules=$(api GET "/nodes/$NODE/lxc/$VMID/firewall/rules")
want_rules="in ACCEPT $WORKSTATIONS $ADDR tcp 22 1 | out ACCEPT - $ROUTER30 udp 53 1 | out ACCEPT - $ROUTER30 tcp 53 1 | out ACCEPT - $HOST tcp 22,8006 1 | out ACCEPT - +internet tcp 443 1"
ok "the five rules, field by field" "$want_rules" "$(js "print(' | '.join(' '.join(str(r.get(k, '-')) for k in ('type', 'action', 'source', 'dest', 'proto', 'dport', 'enable')) + ''.join(' +' + k for k in ('sport', 'iface', 'macro', 'icmp-type') if r.get(k)) for r in sorted(d, key=lambda r: r['pos'])))" <<<"$rules")"
ok "the address set holds the container's address only" "$ADDR" "$(api GET "/nodes/$NODE/lxc/$VMID/firewall/ipset/ipfilter-net0" | js "print(' '.join(sorted(e['cidr'] for e in d)))")"
ok "the set 'internet', every entry" "!10.0.0.0/8 !100.64.0.0/10 !169.254.0.0/16 !172.16.0.0/12 !192.168.0.0/16 0.0.0.0/1 128.0.0.0/1" \
	"$(api GET "/nodes/$NODE/lxc/$VMID/firewall/ipset/internet" | js "print(' '.join(sorted(('!' if e.get('nomatch') else '') + e['cidr'] for e in d)))")"

echo "== the same filter as the hypervisor has loaded it"
hostfacts=$(
	host <<EOF
echo "file=\$(test -s /etc/pve/firewall/$VMID.fw && echo present || echo missing)"
echo "l2=\$(grep -c '^layer2_protocols: ARP\$' /etc/pve/firewall/$VMID.fw 2>/dev/null)"
echo "compile=\$(pve-firewall compile 2>&1 >/dev/null | wc -l)"
echo "daemon=\$(pve-firewall status | head -n 1)"
# The daemon loads a change within its ten second cycle.
for i in 1 2 3 4 5 6 7 8 9 10; do [ "\$(iptables -S veth${VMID}i0-OUT 2>/dev/null | wc -l)" -gt 5 ] && break; sleep 2; done
echo "outchain=\$(iptables -S veth${VMID}i0-OUT 2>/dev/null | wc -l)"
echo "inchain=\$(iptables -S veth${VMID}i0-IN 2>/dev/null | wc -l)"
echo "udp=\$(iptables -S veth${VMID}i0-OUT 2>/dev/null | grep -c -- '-p udp')"
echo "udp67=\$(iptables -S veth${VMID}i0-OUT 2>/dev/null | grep -c -- '--dport 67')"
echo "v6accept=\$(ip6tables -S veth${VMID}i0-OUT 2>/dev/null | grep -c -- 'PVEFW-SET-ACCEPT-MARK')"
echo "arpdrop=\$(ebtables -L veth${VMID}i0-OUT-ARP 2>/dev/null | grep -c -- '-j DROP')"
echo "protoarp=\$(ebtables -L veth${VMID}i0-OUT-PROTO 2>/dev/null | grep -c -- '-p ARP -j RETURN')"
echo "protodrop=\$(ebtables -L veth${VMID}i0-OUT-PROTO 2>/dev/null | grep -c -- '-j DROP')"
set=\$(iptables -S veth${VMID}i0-OUT 2>/dev/null | sed -n 's/.*--match-set \(PVEFW-[^ ]*\) dst.*/\1/p' | head -n 1)
for a in 1.1.1.1 10.0.50.201 192.168.1.196 100.64.0.1 172.16.0.1 169.254.1.1; do echo "in_\$a=\$(ipset test "\$set" \$a 2>&1 | grep -c 'is in set')"; done
echo "running=\$(pct status $VMID 2>/dev/null | awk '{print \$2}')"
echo "fwbr=\$(ip -br link show fwbr${VMID}i0 2>/dev/null | wc -l)"
echo "port=\$(bridge vlan show dev fwpr${VMID}p0 2>/dev/null | awk 'NR>1 { if (\$1 ~ /^[0-9]+\$/) print \$1; else print \$2 }' | xargs)"
EOF
)
hf() { sed -n "s/^$1=//p" <<<"$hostfacts" | head -n 1; }
ok "the guest's firewall file on the hypervisor" present "$(hf file)"
ok "the file asks for ARP as the only other frame type" 1 "$(hf l2)"
ok "the firewall files compile without a word" 0 "$(hf compile)"
ok "the firewall daemon" "Status: enabled/running" "$(hf daemon)"
ok "an outbound chain for the device is loaded" yes "$([ "$(hf outchain)" -gt 5 ] && echo yes || echo no)"
ok "an inbound chain for the device is loaded" yes "$([ "$(hf inchain)" -gt 2 ] && echo yes || echo no)"
ok "UDP let out: one line, the name lookups" 1 "$(hf udp)"
ok "no DHCP let out" 0 "$(hf udp67)"
ok "over IPv6 only the HTTPS rule exists, and its set is empty" 1 "$(hf v6accept)"
ok "ARP from another address is dropped" 1 "$(hf arpdrop)"
ok "frame types: ARP passes on" 1 "$(hf protoarp)"
ok "frame types: the rest is dropped, tagged frames among them" 1 "$(hf protodrop)"
ok "1.1.1.1 counts as internet" 1 "$(hf in_1.1.1.1)"
for a in 10.0.50.201 192.168.1.196 100.64.0.1 172.16.0.1 169.254.1.1; do
	ok "$a does not count as internet" 0 "$(hf "in_$a")"
done

if [ "$(hf running)" != running ]; then
	echo
	echo "the container is $(hf running): the probes from inside it are skipped"
	if [ "$MODE" = layers ]; then
		ok "the container runs (the layers form needs it)" running "$(hf running)"
	fi
else
	echo "== the device of the running container"
	ok "the filtering bridge of the device exists" 1 "$(hf fwbr)"
	ok "its port carries VLAN 30 only" 30 "$(hf port)"

	# One round of probes from inside the container.
	#   <label> <what every closed target must show> <what the second address must show>
	# The two layers answer differently: the hypervisor's filter drops (no
	# answer: "filtered"), the router rejects (an answer: "refused").
	round() {
		local label=$1 kind=$2 second=$3 out t p exp got
		out=$(
			"${CT_SSH[@]}" bash -s <<'EOF' 2>/dev/null
probe() {
	local o rc
	o=$(timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>&1); rc=$?
	case $rc in 0) r=open ;; 124) r=filtered ;; *) case "$o" in *refused*) r=refused ;; *) r=unreachable ;; esac ;; esac
	echo "$1 $2 $r"
}
for t in "10.0.10.10 22" "10.0.10.10 8006" "10.0.10.10 9100" "10.0.10.10 3128" "10.0.10.1 22" "10.0.10.2 22" \
	"192.168.1.53 22" "192.168.1.196 8007" "10.0.50.201 443" "10.0.31.1 53" "10.0.30.1 22" "1.1.1.1 443" "1.1.1.1 80" "9.9.9.9 53"; do
	probe $t
done
echo "dns $(getent hosts deb.debian.org >/dev/null 2>&1 && echo answered || echo silent)"
echo "v6 $(ip -6 -o addr show dev eth0 scope global 2>/dev/null | wc -l) $(ip -6 route show default 2>/dev/null | wc -l)"
# A second address in the network: who refuses it? The address is removed
# before anything is written, so a lost session cannot leave it behind.
ip addr add 10.0.30.11/24 dev eth0 2>/dev/null
o=$(ssh -b 10.0.30.11 -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null nobody@10.0.10.10 true 2>&1)
ip addr del 10.0.30.11/24 dev eth0 2>/dev/null
case "$o" in *"timed out"*) echo "second filtered" ;; *refused* | *nreachable* | *"No route"*) echo "second refused" ;; *denied* | *"Host key"*) echo "second open" ;; *) echo "second unknown" ;; esac
exit 0
EOF
		) || {
			echo "  FAIL  $label: no SSH login to the container from the workstation (E17)"
			fail=$((fail + 1))
			checks=$((checks + 1))
			return
		}
		ok "$label: SSH from the workstation into the container (E17)" yes yes
		while read -r t p exp; do
			got=$(sed -n "s/^$t $p //p" <<<"$out")
			[ "$exp" = closed ] && exp=$kind
			# "unreachable" is the router's answer too, in another form.
			[ "$exp" = refused ] && [ "$got" = unreachable ] && got=refused
			ok "$label: $t port $p" "$exp" "$got"
		done <<'EOF'
10.0.10.10 22 open
10.0.10.10 8006 open
10.0.10.10 9100 closed
10.0.10.10 3128 closed
10.0.10.1 22 closed
10.0.10.2 22 closed
192.168.1.53 22 closed
192.168.1.196 8007 closed
10.0.50.201 443 closed
10.0.31.1 53 closed
10.0.30.1 22 closed
1.1.1.1 443 open
1.1.1.1 80 closed
9.9.9.9 53 closed
EOF
		ok "$label: name lookups at the router" answered "$(sed -n 's/^dns //p' <<<"$out")"
		ok "$label: global IPv6 addresses and IPv6 default routes" "0 0" "$(sed -n 's/^v6 //p' <<<"$out")"
		ok "$label: a second address in the network, towards the hypervisor" "$second" "$(sed -n 's/^second //p' <<<"$out")"
	}

	echo "== from inside the container, every layer on (what is closed gets no answer: the hypervisor's filter)"
	# The second address is dropped at the device and never reaches the
	# router. This holds for frames without a VLAN tag; tagged frames are
	# dropped by the frame-type rule read back above, not probed here.
	round "all layers" filtered filtered

	if [ "$MODE" = layers ] && [ "$fail" -ne 0 ]; then
		echo "  FAIL  the layers round is skipped: the first round failed, and the filter is not switched off on a container that is not as designed"
		fail=$((fail + 1))
		checks=$((checks + 1))
	elif [ "$MODE" = layers ]; then
		echo "== the hypervisor's filter switched off: the router alone (what is closed is refused with an answer)"
		# shellcheck disable=SC2029  # the guest id is expanded here on purpose
		chain() { ssh "${SSH_OPTS[@]}" "ops@$HOST" "sudo iptables -S veth${VMID}i0-OUT 2>/dev/null | wc -l"; }
		# If this script dies, the hypervisor switches the filter on by itself.
		if ! host >/dev/null 2>&1 <<EOF
systemctl stop homelab-fw$VMID-rearm.timer 2>/dev/null
systemd-run --unit homelab-fw$VMID-rearm --collect --on-active=600 --timer-property=AccuracySec=1s /usr/bin/pvesh set /nodes/$NODE/lxc/$VMID/firewall/options --enable 1
EOF
		then
			echo "  FAIL  the timer that switches the filter back on could not be armed; nothing was switched off"
			exit 1
		fi
		restore() {
			api PUT "/nodes/$NODE/lxc/$VMID/firewall/options" --data 'enable=1' >/dev/null
			for _ in $(seq 1 20); do
				if [ "$(chain)" -gt 5 ]; then
					echo "systemctl stop homelab-fw$VMID-rearm.timer" | host >/dev/null 2>&1
					return 0
				fi
				sleep 2
			done
			echo "  FAIL  the filter did not come back within 40 seconds: run 'just pve-apply' (the hypervisor also switches it on by itself within ten minutes)" >&2
			fail=$((fail + 1))
		}
		trap restore EXIT
		api PUT "/nodes/$NODE/lxc/$VMID/firewall/options" --data 'enable=0' >/dev/null
		for _ in $(seq 1 20); do
			[ "$(chain)" -eq 0 ] && break
			sleep 2
		done
		ok "the device's chain is gone" 0 "$(chain)"
		# The router's rules name the one address, so it refuses the second
		# one with an answer.
		round "router alone" refused refused
		restore
		trap - EXIT
		ok "the device's chain is back" yes "$([ "$(chain)" -gt 5 ] && echo yes || echo no)"
		echo "        the API rewrote the firewall file in its own layout: run 'just pve-apply' once, then 'just test-remote' again" >&2
	fi
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "remote1 as designed: $checks checks, all as expected"
else
	echo "REMOTE1 DIFFERS: $fail of $checks checks disagree"
	exit 1
fi
