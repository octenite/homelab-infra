#!/bin/bash
# The administration container of Phase R, read back and probed (steps R.7
# and R.8; docs/phases/phase-r-plan.md, docs/ARCHITECTURE.md section 6, E15
# to E17).
#
#   scripts/tests/remote.sh             (or: just test-remote)
#   scripts/tests/remote.sh layers      also switches the layers off one by
#                                       one, to show which layer refuses what
#
# Runs at home, in WSL, with a session open. Read-only, with these exceptions,
# each undone by the script: inside the container it adds a second address
# for one probe; the "layers" form switches the container's own filter and
# then the hypervisor's off for one round of probes each (each under a timer
# on that host that switches it on again if this script dies); and the API
# write to the hypervisor's filter leaves its file in Proxmox's own layout,
# which the next `just pve-apply` puts back.
#
# Three layers answer differently to a connection the design forbids:
#   the container's own filter   refuses at once, "Operation not permitted"
#   the hypervisor's filter      drops: no answer within the time limit
#   the router                   rejects: an answer comes back
# The container's filter exists once its role has run (step R.8); before that
# the first layer is absent and the expectations say so.
#
# With the container stopped, the read-back runs alone. In the "layers" form
# a stopped container is a failure.
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
TS_VERSION=$(sed -n 's/^remote_ct_tailscale_version:[[:space:]]*//p' "$REPO/infrastructure/ansible/playbooks/group_vars/remote.yaml")
TOKEN_ID='terraform@pve!tofu'
CA="$REPO/private/proxmox/pve1-ca.crt"
TOKENS="$REPO/private/proxmox/tokens.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/dev/shm/homelab-session/age.key}"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

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

	# Into the container: as the operator account once the role has run, as
	# root before (a fresh container holds root's keys only). The host key
	# is remembered under a name, because a rebuild changes it.
	CT_SSH=(ssh "${SSH_OPTS[@]}" -o HostKeyAlias=remote1 -o StrictHostKeyChecking=accept-new)
	if "${CT_SSH[@]}" "ops@$ADDR" true 2>/dev/null; then
		ct() { "${CT_SSH[@]}" "ops@$ADDR" sudo bash -s; }
		ct_user=ops
	else
		ct() { "${CT_SSH[@]}" "root@$ADDR" bash -s; }
		ct_user=root
	fi
	# The container's own filter exists once the role has run.
	role=$(ct <<<'nft list table inet homelab >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)
	echo "        login as $ct_user; the container's own filter: ${role:-unknown}"

	if [ "$role" = yes ]; then
		echo "== what the role left inside (step R.8)"
		inside=$(
			# A quoted heredoc: nothing here is expanded on this side, and the
			# python one-liners keep their double quotes as written.
			ct <<'EOF' 2>/dev/null
echo "state=$(systemctl is-system-running)"
echo "failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | xargs)"
echo "masked=$(systemctl is-enabled dev-mqueue.mount run-lock.mount tmp.mount 2>/dev/null | grep -c '^masked$')"
echo "forward=$(sysctl -n net.ipv4.ip_forward)"
echo "v6=$(ip -6 -o addr show dev eth0 | wc -l)"
echo "listen=$(ss -H -ltn | awk '{print $4}' | sort | xargs)"
echo "tsuser=$(stat -c %U /proc/$(systemctl show -p MainPID --value tailscaled 2>/dev/null) 2>/dev/null)"
echo "tscap=$(grep CapBnd /proc/$(systemctl show -p MainPID --value tailscaled 2>/dev/null)/status 2>/dev/null | awk '{print $2}')"
echo "tun=$(test -e /dev/net/tun && echo present || echo absent)"
echo "version=$(dpkg-query -W -f='${Version}' tailscale 2>/dev/null)"
echo "hold=$(apt-mark showhold 2>/dev/null | grep -c '^tailscale$')"
echo "nftrules=$(nft list ruleset 2>/dev/null | grep -c skuid)"
echo "lodrop=$(nft list chain inet homelab output 2>/dev/null | grep 'oif "lo" meta skuid' | sed -n 's/.*packets \([0-9]*\).*/\1/p')"
echo "backend=$(tailscale status --json --peers=false 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("Self") or {}; print(d.get("BackendState"), "tags=" + ",".join(s.get("Tags") or []), "routes=" + ",".join(s.get("PrimaryRoutes") or []), "health=" + str(len(d.get("Health") or [])))')"
echo "lock=$(tailscale lock status 2>/dev/null | grep -c 'accessible under Tailnet Lock')"
echo "prefs=$(tailscale debug prefs 2>/dev/null | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p.get("CorpDNS"), p.get("RouteAll"), p.get("RunSSH"), p.get("RunWebClient"), ",".join(p.get("AdvertiseRoutes") or []), (p.get("AutoUpdate") or {}).get("Check"), (p.get("AutoUpdate") or {}).get("Apply"))')"
echo "timer=$(test -f /etc/systemd/system/remote-health.timer && systemctl is-active remote-health.timer 2>/dev/null)"
EOF
		)
		inf() { sed -n "s/^$1=//p" <<<"$inside" | head -n 1; }
		ok "systemd's own verdict" running "$(inf state)"
		ok "failed units" "" "$(inf failed)"
		ok "the three tmpfs mount units masked" 3 "$(inf masked)"
		ok "kernel forwarding off" 0 "$(inf forward)"
		ok "no IPv6 address on the device at all" 0 "$(inf v6)"
		ok "listeners: SSH on the container's address only" "$ADDR:22" "$(inf listen)"
		ok "tailscaled runs as its own user" tailscaled "$(inf tsuser)"
		ok "tailscaled holds no capability" 0000000000000000 "$(inf tscap)"
		ok "no TUN device" absent "$(inf tun)"
		ok "tailscale at the pinned version" "$TS_VERSION" "$(inf version)"
		ok "the package held" 1 "$(inf hold)"
		ok "the container's filter matches by user" yes "$([ "$(inf nftrules)" -ge 3 ] && echo yes || echo no)"
		# The rule that drops the tunnel user's loopback traffic must be in
		# place. Its counter is informational: tailscaled may make a loopback
		# attempt at startup, which this rule correctly drops (a non-zero count
		# is the protection working, not a fault).
		ok "the drop of the tunnel user's loopback traffic is in place" yes "$([ -n "$(inf lodrop)" ] && echo yes || echo no)"
		echo "        the tunnel user's loopback attempts dropped so far: $(inf lodrop)"
		echo "        tailscale: $(inf backend); node signed: $(inf lock); prefs (dns routes ssh web | advertised | update check apply): $(inf prefs)"
		case "$(inf backend)" in
		Running*)
			ok "the node carries its tag" yes "$(grep -q 'tags=tag:remote-admin' <<<"$(inf backend)" && echo yes || echo no)"
			ok "the one route is approved" yes "$(grep -q 'routes=10.0.10.10/32' <<<"$(inf backend)" && echo yes || echo no)"
			ok "no health warning" yes "$(grep -q 'health=0' <<<"$(inf backend)" && echo yes || echo no)"
			ok "the node is signed" 1 "$(inf lock)"
			ok "preferences" "False False False False 10.0.10.10/32 False False" "$(inf prefs)"
			;;
		NeedsLogin*) echo "        not logged in yet: the owner's step (just remote-login)" ;;
		NoState* | Starting*) echo "        the daemon is still connecting: run the test again in a few seconds" ;;
		*) ok "the daemon answers" "Running or NeedsLogin" "$(inf backend)" ;;
		esac
		if [ -n "$(inf timer)" ]; then
			ok "the health timer" active "$(inf timer)"
			case "$(inf backend)" in
			Running*)
				# A report made now, not the last one: the timer's last run may predate the signature.
				ok "a health report made now" 0 "$(ct <<<'systemctl start remote-health.service >/dev/null 2>&1; systemctl show -p ExecMainStatus --value remote-health.service' 2>/dev/null)"
				;;
			*) echo "        the health report says failure until the node is logged in and signed" ;;
			esac
		else
			echo "        no health timer yet (the dead-man's switch is not stored)"
		fi
	fi

	# One round of probes from inside the container, as one user.
	#   <label> <user> <what every closed target must show> <what the second address must show>
	round() {
		local label=$1 user=$2 kind=$3 second=$4 tunnel_root=${5:-open} out t p exp got
		out=$(
			ct <<EOF 2>/dev/null
run() { if [ "$user" = root ]; then bash -c "\$1"; else runuser -u "$user" -- bash -c "\$1"; fi; }
probe() {
	local o rc
	o=\$(run "timeout 4 bash -c 'exec 3<>/dev/tcp/\$1/\$2'" 2>&1); rc=\$?
	case \$rc in 0) r=open ;; 124) r=filtered ;; *) case "\$o" in *"not permitted"* | *"Permission denied"*) r=forbidden ;; *refused*) r=refused ;; *nreachable* | *"No route"*) r=unreachable ;; *) r=error ;; esac ;; esac
	echo "\$1 \$2 \$r"
}
for t in "10.0.10.10 22" "10.0.10.10 8006" "10.0.10.10 9100" "10.0.10.10 3128" "10.0.10.1 22" "10.0.10.2 22" \
	"192.168.1.53 22" "192.168.1.196 8007" "10.0.50.201 443" "10.0.31.1 53" "10.0.30.1 22" "1.1.1.1 443" "1.1.1.1 80" "9.9.9.9 53"; do
	probe \$t
done
echo "dns \$(run 'getent hosts deb.debian.org' >/dev/null 2>&1 && echo answered || echo silent)"
echo "v6 \$(ip -6 -o addr show dev eth0 scope global 2>/dev/null | wc -l) \$(ip -6 route show default 2>/dev/null | wc -l)"
# A second address in the network: who refuses it? Added and removed by
# root; the connection is tried by the user of this round. The address is
# removed before anything is written, so a lost session cannot leave it.
ip addr add 10.0.30.11/24 dev eth0 2>/dev/null
o=\$(run "ssh -b 10.0.30.11 -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null nobody@10.0.10.10 true" 2>&1)
ip addr del 10.0.30.11/24 dev eth0 2>/dev/null
case "\$o" in *"timed out"*) echo "second filtered" ;; *"not permitted"* | *"Permission denied"*) echo "second forbidden" ;; *refused* | *nreachable* | *"No route"*) echo "second refused" ;; *denied* | *"Host key"*) echo "second open" ;; *) echo "second unknown" ;; esac
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
			# The hypervisor's two ports: the tunnel user reaches them. Root is
			# stopped by the container's per-user rule while that filter is
			# loaded (a silent drop, so the connect times out: "filtered") and
			# reaches them once the filter is removed. tunnel_root carries that
			# expectation, which is how a layers run tells the container's own
			# filter apart from the hypervisor's (a local TCP drop never returns
			# "permission denied" to the sender, so "forbidden" is not usable).
			[ "$exp" = tunnel ] && { if [ "$user" = root ]; then exp=$tunnel_root; else exp=open; fi; }
			[ "$exp" = closed ] && exp=$kind
			# "unreachable" is the router's answer too, in another form.
			[ "$exp" = refused ] && [ "$got" = unreachable ] && got=refused
			ok "$label: $t port $p" "$exp" "$got"
		done <<'EOF'
10.0.10.10 22 tunnel
10.0.10.10 8006 tunnel
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

	# The user that stands for the tunnel's process once the role has run.
	tun_user=root
	[ "$role" = yes ] && tun_user=tailscaled

	if [ "$role" = yes ]; then
		echo "== from inside the container, every layer on: as root, the container's own filter drops what the design forbids, the hypervisor's two ports included (a silent drop: the connect times out)"
		round "all layers, root" root filtered filtered filtered
		echo "== the same as the tunnel's process: it reaches the hypervisor's two ports; the second address is dropped by the hypervisor's filter (no answer)"
		round "all layers, tunnel" tailscaled filtered filtered
	else
		echo "== from inside the container, every layer on (what is closed gets no answer: the hypervisor's filter)"
		round "all layers" root filtered filtered
	fi

	if [ "$MODE" = layers ] && [ "$fail" -ne 0 ]; then
		echo "  FAIL  the layers round is skipped: the first round failed, and no filter is switched off on a container that is not as designed"
		fail=$((fail + 1))
		checks=$((checks + 1))
	elif [ "$MODE" = layers ]; then
		# shellcheck disable=SC2029  # the guest id is expanded here on purpose
		chain() { ssh "${SSH_OPTS[@]}" "ops@$HOST" "sudo iptables -S veth${VMID}i0-OUT 2>/dev/null | wc -l"; }
		ct_table() { ct <<<'nft list table inet homelab >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null; }

		if [ "$role" = yes ]; then
			echo "== the container's own filter switched off: the hypervisor's filter alone. As root now reaches the hypervisor's two ports, the container being the only layer that stops root there; what the address and port policy forbids still gets no answer"
			# If this script dies, the container reloads its filter by itself.
			if ! ct >/dev/null 2>&1 <<'EOF'
systemctl stop homelab-nft-rearm.timer 2>/dev/null
systemd-run --unit homelab-nft-rearm --collect --on-active=300 --timer-property=AccuracySec=1s systemctl restart nftables
EOF
			then
				echo "  FAIL  the timer that reloads the container's filter could not be armed; nothing was switched off"
				exit 1
			fi
			restore_ct() {
				ct <<<'systemctl restart nftables; systemctl stop homelab-nft-rearm.timer 2>/dev/null' >/dev/null 2>&1
				[ "$(ct_table)" = yes ] || {
					echo "  FAIL  the container's filter did not come back: run 'just remote-apply'" >&2
					fail=$((fail + 1))
				}
			}
			trap restore_ct EXIT
			ct <<<'nft delete table inet homelab' >/dev/null 2>&1
			ok "the container's table is gone" no "$(ct_table)"
			round "hypervisor alone" root filtered filtered open
			restore_ct
			trap - EXIT
			ok "the container's table is back" yes "$(ct_table)"
		fi

		echo "== the hypervisor's filter switched off too: the router alone (what is closed is refused with an answer)"
		# If this script dies, the hypervisor switches its filter on by itself.
		if ! host >/dev/null 2>&1 <<EOF
systemctl stop homelab-fw$VMID-rearm.timer 2>/dev/null
systemd-run --unit homelab-fw$VMID-rearm --collect --on-active=600 --timer-property=AccuracySec=1s /usr/bin/pvesh set /nodes/$NODE/lxc/$VMID/firewall/options --enable 1
EOF
		then
			echo "  FAIL  the timer that switches the hypervisor's filter back on could not be armed; nothing was switched off"
			exit 1
		fi
		restore_host() {
			api PUT "/nodes/$NODE/lxc/$VMID/firewall/options" --data 'enable=1' >/dev/null
			for _ in $(seq 1 20); do
				if [ "$(chain)" -gt 5 ]; then
					echo "systemctl stop homelab-fw$VMID-rearm.timer" | host >/dev/null 2>&1
					return 0
				fi
				sleep 2
			done
			echo "  FAIL  the hypervisor's filter did not come back within 40 seconds: run 'just pve-apply' (the hypervisor also switches it on by itself within ten minutes)" >&2
			fail=$((fail + 1))
		}
		both_back() {
			[ "$role" = yes ] && restore_ct
			restore_host
		}
		trap both_back EXIT
		if [ "$role" = yes ]; then
			if ! ct >/dev/null 2>&1 <<'EOF'
systemctl stop homelab-nft-rearm.timer 2>/dev/null
systemd-run --unit homelab-nft-rearm --collect --on-active=300 --timer-property=AccuracySec=1s systemctl restart nftables
EOF
			then
				echo "  FAIL  the timer that reloads the container's filter could not be armed; the hypervisor's filter stays on"
				trap - EXIT
				echo "systemctl stop homelab-fw$VMID-rearm.timer" | host >/dev/null 2>&1
				exit 1
			fi
			ct <<<'nft delete table inet homelab' >/dev/null 2>&1
		fi
		api PUT "/nodes/$NODE/lxc/$VMID/firewall/options" --data 'enable=0' >/dev/null
		for _ in $(seq 1 20); do
			[ "$(chain)" -eq 0 ] && break
			sleep 2
		done
		ok "the device's chain on the hypervisor is gone" 0 "$(chain)"
		# The router's rules name the one address, so it refuses the second
		# one with an answer.
		round "router alone" "$tun_user" refused refused
		both_back
		trap - EXIT
		ok "the device's chain on the hypervisor is back" yes "$([ "$(chain)" -gt 5 ] && echo yes || echo no)"
		[ "$role" = yes ] && ok "the container's table is back" yes "$(ct_table)"
		echo "        the API rewrote the hypervisor's firewall file in its own layout: run 'just pve-apply' once, then 'just test-remote' again" >&2
	fi
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "remote1 as designed: $checks checks, all as expected"
else
	echo "REMOTE1 DIFFERS: $fail of $checks checks disagree"
	exit 1
fi
