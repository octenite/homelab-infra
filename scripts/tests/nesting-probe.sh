#!/bin/bash
# Does the pinned Debian template run properly as an unprivileged container
# WITHOUT the hypervisor's nesting feature? Decides the value of `nesting` in
# infrastructure/opentofu/roots/remote/main.tf, which can be set at creation
# only (docs/runbooks/rebuild-remote1.md).
#
#   scripts/tests/nesting-probe.sh        (or: just nesting-probe)
#
# It creates one throwaway container (guest id 9909, pool remote, no network
# device, no feature) with the OpenTofu token, starts it, looks at it as the
# operator through `pct exec`, and destroys it in every case. Run at home,
# with a session open, before a container is built from a new template.
#
# The answer is "nesting needed" when one of these holds:
#   - systemd does not reach "running" (a "degraded" state names its units);
#   - a unit failed with status 226/NAMESPACE or 243/CREDENTIALS;
#   - the login service or the SSH service is not active;
#   - a login through PAM takes longer than five seconds.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=10.0.10.10
NODE=pve1
ID=9909
TOKEN_ID='terraform@pve!tofu'
CA="$REPO/private/proxmox/pve1-ca.crt"
TOKENS="$REPO/private/proxmox/tokens.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/dev/shm/homelab-session/age.key}"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
[ -r "$SOPS_AGE_KEY_FILE" ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}
secret=$(sops decrypt --extract "[\"$TOKEN_ID\"][\"secret\"]" "$TOKENS") || exit 1
TEMPLATE="local:vztmpl/$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["template_file"])' \
	"$REPO/infrastructure/opentofu/roots/remote/template.auto.tfvars.json")"
BODY=$(mktemp)

request() { # <method> <path> [curl arguments] -> status; body in $BODY
	local method=$1 path=$2
	shift 2
	printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$TOKEN_ID" "$secret" |
		curl --config - --silent --output "$BODY" --write-out '%{http_code}' \
			--cacert "$CA" --max-time 30 --request "$method" "$@" "https://$HOST:8006/api2/json$path"
}
data() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("data") or "")' "$BODY" 2>/dev/null; }
wait_task() { # <upid> ; succeeds when the task ended with OK or with warnings
	local upid
	upid=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")
	for _ in $(seq 1 120); do
		request GET "/nodes/$NODE/tasks/$upid/status" >/dev/null
		if [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["data"]["status"])' "$BODY" 2>/dev/null)" = stopped ]; then
			python3 -c 'import json, sys
e = json.load(open(sys.argv[1]))["data"].get("exitstatus", "")
print("   task ended:", e)
sys.exit(0 if e == "OK" or e.startswith("WARNINGS") else 1)' "$BODY"
			return
		fi
		sleep 2
	done
	return 1
}
on_host() { ssh -o BatchMode=yes -o ConnectTimeout=8 "ops@$HOST" sudo sh -s; }
remove() {
	trap - EXIT
	echo "== removing the throwaway container"
	if [ "$(request POST "/nodes/$NODE/lxc/$ID/status/stop")" = 200 ]; then wait_task "$(data)" >/dev/null || true; fi
	if [ "$(request DELETE "/nodes/$NODE/lxc/$ID?purge=1")" = 200 ]; then wait_task "$(data)" >/dev/null || true; fi
	if [ "$(request GET "/cluster/nextid?vmid=$ID")" = 200 ]; then
		echo "   guest id $ID is free again"
	else
		echo "   !! container $ID is still there; remove it by hand: ssh ops@$HOST 'sudo pct stop $ID; sudo pct destroy $ID --purge'"
	fi
	rm -f "$BODY"
}

[ "$(request GET "/cluster/nextid?vmid=$ID")" = 200 ] || {
	echo "guest id $ID is in use; nothing was created" >&2
	rm -f "$BODY"
	exit 1
}
echo "== creating container $ID from $TEMPLATE: unprivileged, no feature, no network device"
got=$(request POST "/nodes/$NODE/lxc" --data-urlencode "vmid=$ID" --data-urlencode "ostemplate=$TEMPLATE" \
	--data-urlencode 'storage=local-lvm' --data-urlencode 'pool=remote' --data-urlencode 'unprivileged=1' \
	--data-urlencode 'hostname=nesting-probe' --data-urlencode 'memory=256' --data-urlencode 'swap=0' \
	--data-urlencode 'ostype=debian' --data-urlencode 'start=0')
[ "$got" = 200 ] || {
	echo "the creation was refused: HTTP $got $(cat "$BODY")" >&2
	rm -f "$BODY"
	exit 1
}
trap remove EXIT
wait_task "$(data)" || {
	echo "the creation task failed" >&2
	exit 1
}
if [ "$(request POST "/nodes/$NODE/lxc/$ID/status/start")" != 200 ] || ! wait_task "$(data)"; then
	echo "the container did not start" >&2
	exit 1
fi

echo "== looking at it"
facts=$(
	on_host <<EOF
echo "state=\$(timeout 150 pct exec $ID -- systemctl is-system-running --wait 2>/dev/null | tail -n 1)"
echo "failed=\$(pct exec $ID -- systemctl --failed --no-legend --plain 2>/dev/null | awk '{print \$1}' | xargs)"
echo "sandbox=\$(pct exec $ID -- journalctl -b --no-pager 2>/dev/null | grep -c -E 'status=226/NAMESPACE|status=243/CREDENTIALS')"
echo "logind=\$(pct exec $ID -- systemctl is-active systemd-logind 2>/dev/null)"
echo "ssh=\$(pct exec $ID -- systemctl is-active ssh 2>/dev/null)"
s=\$(date +%s%N); pct exec $ID -- su -l root -c true >/dev/null 2>&1; e=\$(date +%s%N)
echo "login_ms=\$(( (e - s) / 1000000 ))"
echo "virt=\$(pct exec $ID -- systemd-detect-virt 2>/dev/null)"
echo "tools=\$(pct exec $ID -- sh -c 'for t in python3 ssh sshd curl ip timeout getent; do command -v \$t >/dev/null 2>&1 && printf \"%s \" \$t; done')"
echo "systemd=\$(pct exec $ID -- systemctl --version 2>/dev/null | head -n 1)"
pct exec $ID -- journalctl -b --no-pager -p warning 2>/dev/null | tail -n 12 | sed 's/^/log: /'
EOF
)
f() { sed -n "s/^$1=//p" <<<"$facts" | head -n 1; }
show() {
	printf '   %-34s %s\n' "systemd's own verdict" "$(f state)" "failed units" "$(f failed | sed 's/^$/none/')" \
		"sandbox failures in the journal" "$(f sandbox)" "login service" "$(f logind)" "SSH service" "$(f ssh)" \
		"a login through PAM, milliseconds" "$(f login_ms)" "virtualisation seen inside" "$(f virt)" \
		"tools in the template" "$(f tools)" "systemd" "$(f systemd)"
	sed -n 's/^log: /   | /p' <<<"$facts"
}
show

# The default profile of an unprivileged container refuses the tmpfs mounts
# of /tmp, /dev/mqueue and /run/lock, so systemd reports "degraded" with
# exactly those units failed. None of them is needed here: /tmp and
# /run/lock are directories on a filesystem already, and nothing uses POSIX
# message queues. Masking them is what the container role does (step R.8);
# the probe does the same and looks again, so the verdict is about what is
# left.
MOUNT_UNITS='dev-mqueue.mount run-lock.mount tmp.mount'
masked=no
if [ "$(f state)" != running ] && [ -n "$(f failed)" ]; then
	other=$(tr ' ' '\n' <<<"$(f failed)" | grep -v -x -F -e dev-mqueue.mount -e run-lock.mount -e tmp.mount | xargs)
	if [ -z "$other" ]; then
		echo "== only the three tmpfs mount units failed: masking them and looking again"
		facts=$(
			on_host <<EOF
pct exec $ID -- systemctl mask $MOUNT_UNITS >/dev/null 2>&1
pct reboot $ID >/dev/null 2>&1; sleep 5
echo "state=\$(timeout 150 pct exec $ID -- systemctl is-system-running --wait 2>/dev/null | tail -n 1)"
echo "failed=\$(pct exec $ID -- systemctl --failed --no-legend --plain 2>/dev/null | awk '{print \$1}' | xargs)"
echo "sandbox=\$(pct exec $ID -- journalctl -b --no-pager 2>/dev/null | grep -c -E 'status=226/NAMESPACE|status=243/CREDENTIALS')"
echo "logind=\$(pct exec $ID -- systemctl is-active systemd-logind 2>/dev/null)"
echo "ssh=\$(pct exec $ID -- systemctl is-active ssh 2>/dev/null)"
s=\$(date +%s%N); pct exec $ID -- su -l root -c true >/dev/null 2>&1; e=\$(date +%s%N)
echo "login_ms=\$(( (e - s) / 1000000 ))"
echo "virt=\$(pct exec $ID -- systemd-detect-virt 2>/dev/null)"
echo "tools=masked: $MOUNT_UNITS"
echo "systemd=\$(pct exec $ID -- systemctl --version 2>/dev/null | head -n 1)"
pct exec $ID -- journalctl -b --no-pager -p warning 2>/dev/null | tail -n 12 | sed 's/^/log: /'
EOF
		)
		masked=yes
		show
	fi
fi

needed=no
[ "$(f state)" = running ] || needed=yes
[ "$(f sandbox)" = 0 ] || needed=yes
[ "$(f logind)" = active ] || needed=yes
[ "$(f ssh)" = active ] || needed=yes
[ "$(f login_ms)" -lt 5000 ] 2>/dev/null || needed=yes
echo
if [ "$needed" = no ] && [ "$masked" = no ]; then
	echo "VERDICT: the template runs properly without nesting. Keep nesting = false."
elif [ "$needed" = no ]; then
	echo "VERDICT: the template runs properly without nesting once the units $MOUNT_UNITS are masked, which the container role does. Keep nesting = false."
else
	echo "VERDICT: nesting is needed (or the probe could not tell). This is a deviation from decision D2: put it to the owner before setting nesting = true."
fi
