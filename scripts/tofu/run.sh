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
# A backend override puts the root in offline mode: OpenTofu then works on a
# local copy of the state. Run through this wrapper, a plan would look like a
# plan against the bucket and is not, so the wrapper stays out of that mode.
if compgen -G "$ROOT_DIR/override.tf" >/dev/null || compgen -G "$ROOT_DIR/*_override.tf" >/dev/null; then
	cat >&2 <<EOF
$ROOT_DIR holds a backend override: the root is in offline mode and works on a
local copy of the state, not on the bucket. This wrapper does not run in that mode.
  to keep working offline:   docs/runbooks/tofu-offline.md, part A (OpenTofu is started directly)
  to return to the bucket:   docs/runbooks/tofu-offline.md, part B (it starts by removing the override)
EOF
	exit 2
fi
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
