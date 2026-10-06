#!/bin/bash
# Run OpenTofu for one root with its credentials and state passphrase taken
# from the private repository for the lifetime of the command only.
#
#   run.sh <root> <tofu arguments...>        e.g. run.sh pve plan
#
# After every apply the still-encrypted state is pulled to the workstation
# (private/opentofu/state-copies/, ciphertext, committed) as the break-glass
# copy for a WAN outage (ARCHITECTURE.md section 9).
set -euo pipefail

root=${1:?root name, for example pve}
shift
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ROOT_DIR="$REPO/infrastructure/opentofu/roots/$root"
BACKEND="$REPO/private/opentofu/backend.hcl"
SECRETS="$REPO/private/opentofu/b2.sops.yaml"
COPIES="$REPO/private/opentofu/state-copies"

[ -d "$ROOT_DIR" ] || {
	echo "no such root: $ROOT_DIR" >&2
	exit 2
}
[ -f "$BACKEND" ] || {
	echo "missing $BACKEND (bucket, key, region, endpoints)" >&2
	exit 2
}
[ -r /dev/shm/homelab-session/age.key ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}
export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key

cd "$ROOT_DIR"
cmd=${1:-}
case "$cmd" in
init)
	shift
	set -- init -backend-config="$BACKEND" "$@"
	;;
esac

# The SOPS file's keys become environment variables; the backend expects the
# AWS names, the encryption block its variable. sops runs one command
# string, so the arguments travel shell-quoted in a variable.
TOFU_ARGS=$(printf '%q ' "$@")
export TOFU_ARGS TOFU_ROOT="$root" TOFU_COPIES="$COPIES"
# shellcheck disable=SC2016  # expanded by the child shell, on purpose
sops exec-env "$SECRETS" '
set -euo pipefail
export AWS_ACCESS_KEY_ID="$b2_key_id" AWS_SECRET_ACCESS_KEY="$b2_application_key"
export TF_VAR_state_passphrase="$tofu_state_passphrase"
unset b2_key_id b2_application_key tofu_state_passphrase
eval "set -- $TOFU_ARGS"
tofu "$@"
if [ "${1:-}" = "apply" ]; then
  mkdir -p "$TOFU_COPIES"
  tofu state pull > "$TOFU_COPIES/$TOFU_ROOT.tfstate.enc"
  echo "encrypted state copy saved: private/opentofu/state-copies/$TOFU_ROOT.tfstate.enc (commit it)"
fi
'
