#!/bin/bash
# Started by run.sh under `sops exec-env`: the keys of the SOPS file are
# environment variables here and nowhere else. Not meant to be run by hand.
set -euo pipefail

: "${TOFU_ARGS:?run this through scripts/tofu/run.sh}"
: "${b2_key_id:?b2_key_id is missing in private/opentofu/b2.sops.yaml}"
: "${b2_application_key:?b2_application_key is missing in private/opentofu/b2.sops.yaml}"
: "${tofu_state_passphrase:?tofu_state_passphrase is missing in private/opentofu/b2.sops.yaml}"

# The backend expects the AWS names, the encryption block its variable.
export AWS_ACCESS_KEY_ID="$b2_key_id" AWS_SECRET_ACCESS_KEY="$b2_application_key"
export TF_VAR_state_passphrase="$tofu_state_passphrase"
unset b2_key_id b2_application_key tofu_state_passphrase

eval "set -- $TOFU_ARGS"
cd "$TOFU_ROOT_DIR"

STATE_KEY="$TOFU_ROOT/terraform.tfstate"

hcl() { # <name> : the quoted value of a top-level "name = "value"" line of the backend file
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" "$TOFU_BACKEND" | head -n 1
}

copy_state() {
	# The break-glass copy is the object exactly as the bucket holds it:
	# the state as OpenTofu encrypted it, usable offline with a local
	# backend and the same passphrase (docs/runbooks/tofu-offline.md).
	# `tofu state pull` would print the state in the clear, so it is not
	# used. The credentials go to curl on standard input, not as arguments.
	local dir="$TOFU_REPO/private/opentofu/state-copies"
	local out="$dir/$TOFU_ROOT.state.json"
	local bucket region endpoint tmp
	bucket=$(hcl bucket)
	region=$(hcl region)
	endpoint=$(sed -n 's/.*s3[[:space:]]*=[[:space:]]*"\(https:[^"]*\)".*/\1/p' "$TOFU_BACKEND" | head -n 1)
	if [ -z "$bucket" ] || [ -z "$region" ] || [ -z "$endpoint" ]; then
		echo "WARNING: no state copy was saved: bucket, region or endpoint not found in $TOFU_BACKEND" >&2
		return
	fi
	mkdir -p "$dir"
	tmp=$(mktemp "$dir/.$TOFU_ROOT.XXXXXX")
	if printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" |
		curl --fail --silent --show-error --config - --aws-sigv4 "aws:amz:$region:s3" \
			--output "$tmp" "${endpoint%/}/$bucket/$STATE_KEY" &&
		grep -q '"encrypted_data"' "$tmp" && ! grep -q '"resources"' "$tmp"; then
		mv "$tmp" "$out"
		echo "state copy saved (ciphertext, as stored in the bucket): private/opentofu/state-copies/$TOFU_ROOT.state.json; commit it"
	else
		rm -f "$tmp"
		echo "WARNING: no state copy was saved (object not readable, or not an encrypted state); the previous copy is unchanged" >&2
	fi
}

case "$1" in
init)
	shift
	exec tofu init -backend-config="$TOFU_BACKEND" -backend-config="key=$STATE_KEY" "$@"
	;;
apply | destroy | import | state | taint | untaint | refresh)
	# Anything here may have changed the state, even when it fails half-way.
	rc=0
	tofu "$@" || rc=$?
	case "$1:${2:-}" in
	state:list | state:show | state:pull) ;;
	*) copy_state ;;
	esac
	exit "$rc"
	;;
*)
	exec tofu "$@"
	;;
esac
