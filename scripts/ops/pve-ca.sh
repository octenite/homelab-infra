#!/bin/bash
# Fetch the hypervisor's CA certificate into the private repository and prove
# that the API's certificate chains to it.
#
#   scripts/ops/pve-ca.sh            (or: just pve-ca)
#
# Proxmox creates its own CA at install time and signs the API's certificate
# with it. Clients that verify the API (OpenTofu, the token scope test) need
# that CA. It is a public certificate, kept in the private repository with the
# host's other identifiers. It changes with every reinstall of the hypervisor.
# Runs from the workstation with a session open.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=${PVE_HOST:-10.0.10.10}
OUT="$REPO/private/proxmox/pve1-ca.crt"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"

tmp=$(mktemp /dev/shm/pve-ca.XXXXXX)
trap 'rm -f "$tmp"' EXIT

ssh -o BatchMode=yes -o ConnectTimeout=10 "ops@$HOST" 'sudo cat /etc/pve/pve-root-ca.pem' >"$tmp"
openssl x509 -in "$tmp" -noout >/dev/null || {
	echo "what the hypervisor returned is not a certificate; nothing was written" >&2
	exit 1
}
# The proof: a TLS handshake with the API that trusts this CA and nothing else.
if ! openssl s_client -connect "$HOST:8006" -CAfile "$tmp" -verify_return_error -verify_ip "$HOST" </dev/null >/dev/null 2>&1; then
	echo "the API's certificate at $HOST:8006 does not verify against the fetched CA for the address $HOST; nothing was written" >&2
	exit 1
fi
if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
	echo "unchanged: private/proxmox/pve1-ca.crt"
else
	install -m 0644 "$tmp" "$OUT"
	echo "written: private/proxmox/pve1-ca.crt; commit the private repository"
fi
echo "CA $(openssl x509 -in "$OUT" -noout -fingerprint -sha256 | cut -d= -f2), valid until $(openssl x509 -in "$OUT" -noout -enddate | cut -d= -f2)"
echo "the API's certificate verifies against it for $HOST"
