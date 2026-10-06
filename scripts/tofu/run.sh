#!/bin/bash
# Run OpenTofu for one root with its credentials and state passphrase taken
# from the private repository for the lifetime of the command only.
#
#   run.sh <root> <tofu arguments...>        e.g. run.sh pve plan
#
# After every command that can change state (successful or not), the state
# object is copied from the bucket, exactly as stored (ciphertext), into
# private/opentofu/state-copies/<root>.state.json: the break-glass copy for
# a WAN outage (ARCHITECTURE.md section 9, docs/runbooks/tofu-offline.md).
set -euo pipefail

usage() {
	echo "usage: $0 <root> <tofu arguments...>   for example: $0 pve plan" >&2
	exit 2
}
[ $# -ge 2 ] || usage
root=$1
shift
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ROOT_DIR="$REPO/infrastructure/opentofu/roots/$root"
BACKEND="$REPO/private/opentofu/backend.hcl"
SECRETS="$REPO/private/opentofu/b2.sops.yaml"

[ -d "$ROOT_DIR" ] || {
	echo "no such root: $ROOT_DIR" >&2
	exit 2
}
[ -f "$BACKEND" ] || {
	cat >&2 <<EOF
missing $BACKEND
It names where the state lives (identifiers, not secrets) and belongs in the private repository:
  bucket    = "<bucket name>"
  region    = "<region, for example eu-central-003>"
  endpoints = { s3 = "https://s3.<region>.backblazeb2.com" }
The object key is not in the file: every root uses <root>/terraform.tfstate.
EOF
	exit 2
}
[ -r /dev/shm/homelab-session/age.key ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}
export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key

# The child runs under bash, named explicitly: sops starts its command with
# /bin/sh, which is not bash everywhere. The arguments travel shell-quoted.
TOFU_ARGS=$(printf '%q ' "$@")
export TOFU_ARGS TOFU_ROOT="$root" TOFU_ROOT_DIR="$ROOT_DIR" TOFU_BACKEND="$BACKEND" TOFU_REPO="$REPO"
exec sops exec-env "$SECRETS" "bash '$REPO/scripts/tofu/child.sh'"
