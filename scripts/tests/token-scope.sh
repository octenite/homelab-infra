#!/bin/bash
# Scope test of the OpenTofu API token on the hypervisor (backlog B31; Phase R
# steps R.1 and R.7). It proves what the token may do and, more important,
# what it may not.
#
#   scripts/tests/token-scope.sh            (or: just test-token)
#
# Runs from the workstation with a session open. Every write it attempts is a
# no-op by design: it sets an option to the value Git already gives it. If a
# refusal that is expected here ever turns into a success, nothing on the
# host has changed, and the test fails.
#
# The token's secret goes to curl on standard input, never as an argument.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=${PVE_HOST:-10.0.10.10}
NODE=${PVE_NODE:-pve1}
TOKEN_ID='terraform@pve!tofu'
CA="$REPO/private/proxmox/pve1-ca.crt"
TOKENS="$REPO/private/proxmox/tokens.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/dev/shm/homelab-session/age.key}"

[ -r "$SOPS_AGE_KEY_FILE" ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}
[ -r "$CA" ] || {
	echo "missing private/proxmox/pve1-ca.crt; run 'just pve-ca' first" >&2
	exit 1
}
secret=$(sops decrypt --extract "[\"$TOKEN_ID\"][\"secret\"]" "$TOKENS") || exit 1

fail=0
checks=0

# call <method> <path> [curl data arguments...] -> prints the HTTP status
call() {
	local method=$1 path=$2
	shift 2
	printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$TOKEN_ID" "$secret" |
		curl --config - --silent --output /dev/null --write-out '%{http_code}' \
			--cacert "$CA" --max-time 10 --request "$method" "$@" "https://$HOST:8006/api2/json$path"
}

# expect <wanted status> <what it shows> <method> <path> [data...]
expect() {
	local want=$1 what=$2 got
	shift 2
	got=$(call "$@")
	checks=$((checks + 1))
	if [ "$got" = "$want" ]; then
		printf '  ok    %-4s %-44s %s  %s\n' "$1" "$2" "$got" "$what"
	else
		printf '  FAIL  %-4s %-44s %s  expected %s: %s\n' "$1" "$2" "$got" "$want" "$what"
		fail=$((fail + 1))
	fi
}

echo "== certificate"
if curl --silent --output /dev/null --cacert "$CA" --max-time 10 "https://$HOST:8006/"; then
	echo "  ok    the API's certificate verifies against the hypervisor's CA"
else
	echo "  FAIL  the API's certificate does not verify against private/proxmox/pve1-ca.crt"
	fail=$((fail + 1))
fi
checks=$((checks + 1))

echo "== inside the token's scope"
expect 200 "any valid token may read the version" GET /version
expect 200 "its own pool" GET /pools/talos
expect 200 "storage list of its node" GET "/nodes/$NODE/storage"
expect 200 "next free guest id" GET /cluster/nextid

expect 200 "the pool for remote-access containers" GET /pools/remote

# has <path> <privilege> -> yes | no : the token's own answer about itself.
# A privilege counts when it is named at all (its value only says whether it
# is passed down). An answer without the path, or an error, prints nothing,
# and the caller then reports a failure: "no" is never guessed.
has() {
	printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$TOKEN_ID" "$secret" |
		curl --config - --silent --cacert "$CA" --max-time 10 --get --data-urlencode "path=$1" \
			"https://$HOST:8006/api2/json/access/permissions" |
		python3 -c 'import json, sys
d = json.load(sys.stdin)["data"]
print("yes" if sys.argv[2] in d[sys.argv[1]] else "no")' "$1" "$2" 2>/dev/null
}
# may <wanted> <what it shows> <path> <privilege>
may() {
	local got
	got=$(has "$3" "$4")
	checks=$((checks + 1))
	if [ "$got" = "$1" ]; then
		printf '  ok    %-10s %-38s %-3s  %s\n' "$4" "$3" "$got" "$2"
	else
		printf '  FAIL  %-10s %-38s %-3s  expected %s: %s\n' "$4" "$3" "${got:-?}" "$1" "$2"
		fail=$((fail + 1))
	fi
}

# These rows read the token's grants. They do not prove that a guest cannot
# end up elsewhere: Proxmox checks the VLAN of a network device, not the
# pool it belongs to, so either pool may use either VLAN; and by the source
# of the release a device with trunk VLANs and no tag, or a VM device with
# no bridge at all, needs no right on the bridge path (backlog B43). The
# OpenTofu modules, CI and the drift job are what refuses those.
echo "== where the token holds the right to attach a guest: the cluster VLAN and the administration container's"
BR=/sdn/zones/localnetwork/vmbr0
may yes "the cluster" "$BR/50" SDN.Use
may yes "remote access, administration" "$BR/30" SDN.Use
may no "remote access, household: not before its plan" "$BR/31" SDN.Use
may no "no right on the bridge path itself" "$BR" SDN.Use
may no "the direct link to the workstation" /sdn/zones/localnetwork/vmbr1 SDN.Use
may no "nothing at the top" / VM.Allocate
may yes "guests in the remote-access pool" /pool/remote VM.Allocate

# The whole map of the token: the paths on which it holds anything must be
# exactly the ones Git grants (plus the guests in its pools, once any exist).
paths=$(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$TOKEN_ID" "$secret" |
	curl --config - --silent --cacert "$CA" --max-time 10 "https://$HOST:8006/api2/json/access/permissions" |
	python3 -c 'import json, sys
d = json.load(sys.stdin)["data"]
print(" ".join(sorted(p for p, v in d.items() if v and not p.startswith("/vms/"))))' 2>/dev/null)
want="/nodes/$NODE /pool/remote /pool/talos $BR/30 $BR/50 /storage/local /storage/local-lvm"
checks=$((checks + 1))
if [ "$paths" = "$want" ]; then
	echo "  ok    the token holds rights on exactly these seven paths and no other"
else
	echo "  FAIL  the token's paths are: ${paths:-(no answer)}"
	echo "        expected:              $want"
	fail=$((fail + 1))
fi

echo "== outside the token's scope (each write would be a no-op if it were allowed)"
expect 403 "host firewall options: it lost Sys.Modify" PUT "/nodes/$NODE/firewall/options" --data 'ndp=0'
expect 403 "datacenter firewall options" PUT /cluster/firewall/options --data 'enable=1'
expect 403 "backup jobs of the datacenter: no audit right on the root path" GET /cluster/backup
expect 403 "the node's system log: no such right" GET "/nodes/$NODE/syslog"

echo "== without a token"
got=$(curl --silent --output /dev/null --write-out '%{http_code}' --cacert "$CA" --max-time 10 "https://$HOST:8006/api2/json/nodes/$NODE/status")
checks=$((checks + 1))
if [ "$got" = 401 ]; then
	echo "  ok    GET  /nodes/$NODE/status                          401  no ticket, no token"
else
	echo "  FAIL  GET  /nodes/$NODE/status                          $got  expected 401"
	fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "token scope holds: $checks checks, all as expected"
else
	echo "TOKEN SCOPE BROKEN: $fail of $checks checks disagree"
fi
exit "$((fail > 0))"
