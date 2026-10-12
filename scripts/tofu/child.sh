#!/bin/bash
# Started by run.sh under `sops exec-env`: the keys of the SOPS file are
# environment variables here and nowhere else. Not meant to be run by hand.
set -euo pipefail

: "${TOFU_ARGS:?run this through scripts/tofu/run.sh}"
: "${b2_key_id:?b2_key_id is missing in private/opentofu/b2.sops.yaml}"
: "${b2_application_key:?b2_application_key is missing in private/opentofu/b2.sops.yaml}"
: "${tofu_state_passphrase:?tofu_state_passphrase is missing in private/opentofu/b2.sops.yaml}"

# The backend expects the AWS names, the encryption block its variables.
export AWS_ACCESS_KEY_ID="$b2_key_id" AWS_SECRET_ACCESS_KEY="$b2_application_key"
export TF_VAR_state_passphrase="$tofu_state_passphrase"
# While a rotation is under way (scripts/tofu/passphrase.sh) the file also
# holds the previous passphrase, which OpenTofu may fall back to when it
# reads a state. Outside a rotation, and when the caller asks for it, the
# fallback is the current passphrase itself: nothing else can read the state.
if [ -n "${tofu_state_passphrase_previous:-}" ] && [ -z "${TOFU_NO_FALLBACK:-}" ]; then
	export TF_VAR_state_passphrase_previous="$tofu_state_passphrase_previous"
else
	export TF_VAR_state_passphrase_previous="$tofu_state_passphrase"
fi
unset b2_key_id b2_application_key tofu_state_passphrase tofu_state_passphrase_previous

# OpenTofu's own temporary files are not encrypted. When a state is moved
# between backends (`init -migrate-state`) it writes both states in the clear,
# readable by every user, into the temporary directory while it asks its
# question (seen in the rehearsal of 2026-10-07). The workstation's disk is
# not encrypted (X23), so every command gets a private directory in memory,
# removed when the command ends.
umask 077
TMPDIR=$(mktemp -d /dev/shm/tofu.XXXXXX)
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# ---- credentials per root -----------------------------------------------------
# Every root gets the state backend's credentials above. Beyond that, each
# root receives only what it needs, so a mistake or a compromised provider in
# one root cannot use another root's credential.
PVE_TOKEN_ID='terraform@pve!tofu'
PVE_CA="$TOFU_REPO/private/proxmox/pve1-ca.crt"

proxmox_credentials() {
	local tokens="$TOFU_REPO/private/proxmox/tokens.sops.yaml" secret
	[ -r "$PVE_CA" ] || {
		echo "missing $PVE_CA: the hypervisor's CA certificate. Fetch it with 'just pve-ca' (it changes with every reinstall of the hypervisor)." >&2
		exit 2
	}
	secret=$(sops decrypt --extract "[\"$PVE_TOKEN_ID\"][\"secret\"]" "$tokens")
	: "${secret:?no secret for $PVE_TOKEN_ID in private/proxmox/tokens.sops.yaml}"
	export PROXMOX_VE_API_TOKEN="$PVE_TOKEN_ID=$secret"
	# The provider has no setting for a CA of its own, and switching
	# verification off is not an option. OpenTofu and its providers read
	# one bundle file, so the hypervisor's CA is added to the system's
	# bundle in the private temporary directory.
	cat /etc/ssl/certs/ca-certificates.crt "$PVE_CA" >"$TMPDIR/ca-bundle.crt"
	export SSL_CERT_FILE="$TMPDIR/ca-bundle.crt"
}

# The tailnet's policy and settings: an OAuth client limited to those two
# things, and the owner's login, which the policy file names. One encrypted
# file holds all three; they are read one by one so nothing else of it is
# ever in the environment.
tailscale_credentials() {
	local file="$TOFU_REPO/private/tailscale/oauth.sops.yaml" id secret login
	[ -r "$file" ] || {
		echo "missing private/tailscale/oauth.sops.yaml. Store the OAuth client and the login with 'just secret-set' (docs/runbooks/tailnet-setup.md)." >&2
		exit 2
	}
	id=$(sops decrypt --extract '["tailscale_oauth_client_id"]' "$file")
	secret=$(sops decrypt --extract '["tailscale_oauth_client_secret"]' "$file")
	login=$(sops decrypt --extract '["tailscale_owner_login"]' "$file")
	: "${id:?tailscale_oauth_client_id is missing}" "${secret:?tailscale_oauth_client_secret is missing}" "${login:?tailscale_owner_login is missing}"
	export TAILSCALE_OAUTH_CLIENT_ID="$id" TAILSCALE_OAUTH_CLIENT_SECRET="$secret" TF_VAR_owner_login="$login"
}

# Tailscale refuses to save a policy that fails one of its own tests, but a
# plan does not show it: the validation call the provider makes answers "200"
# in that case and names the failed test in the body, which the provider does
# not read (seen on 2026-10-09 with provider 0.29.2: a plan passed with a
# grant that a test forbids, and the save was refused with "400"). So the
# same call is made here before a plan or an apply, and anything but an empty
# answer stops the command. Nothing is changed in the tailnet by it.
tailnet_policy_check() {
	local policy="$TOFU_ROOT_DIR/policy.hujson" rendered="$TMPDIR/policy.rendered" token
	python3 - "$policy" "$rendered" <<'PY'
import os
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
text = text.replace("${owner_login}", os.environ["TF_VAR_owner_login"])
if "${" in text:
    sys.exit("policy.hujson uses a template variable that scripts/tofu/child.sh does not know; add it to tailnet_policy_check")
pathlib.Path(sys.argv[2]).write_text(text)
PY
	token=$(printf 'user = "%s:%s"\n' "$TAILSCALE_OAUTH_CLIENT_ID" "$TAILSCALE_OAUTH_CLIENT_SECRET" |
		curl --fail --silent --show-error --config - --max-time 20 --data 'grant_type=client_credentials' \
			https://api.tailscale.com/api/v2/oauth/token |
		python3 -c 'import json, sys; print(json.load(sys.stdin)["access_token"])')
	printf 'header = "Authorization: Bearer %s"\n' "$token" |
		curl --fail --silent --show-error --config - --max-time 20 \
			--header 'Content-Type: application/hujson' --data-binary "@$rendered" \
			https://api.tailscale.com/api/v2/tailnet/-/acl/validate |
		python3 -c '
import json
import sys

body = sys.stdin.read().strip()
answer = json.loads(body) if body else {}
if answer:
    print("the policy is refused by Tailscale:", answer.get("message", ""), file=sys.stderr)
    for item in answer.get("data") or []:
        for error in item.get("errors") or []:
            print("  " + str(item.get("user", "")) + ": " + error, file=sys.stderr)
    sys.exit(1)
' || {
		echo "infrastructure/opentofu/roots/tailscale/policy.hujson did not pass Tailscale's validation; nothing was planned or applied" >&2
		exit 1
	}
}

# The root "remote": root's keys for a new container, and three guards.
#   - A container is never destroyed or replaced by a plan. The hypervisor
#     refuses to delete a protected one, but only after the provider has
#     stopped it. A rebuild is a runbook (docs/runbooks/rebuild-remote1.md).
#   - A guest id that is taken is never planned onto: the provider would
#     adopt whatever guest holds the id and report it as created.
#   - The template is compared with its pin by run.sh before, and here after.
REMOTE_VMID=3010
REMOTE_ADDRESS=module.remote1.proxmox_virtual_environment_container.this

pve_api() { # <METHOD> <path below /api2/json> ; prints the body, fails on an HTTP error
	printf 'header = "Authorization: PVEAPIToken=%s"\n' "$PROXMOX_VE_API_TOKEN" |
		curl --fail --silent --show-error --config - --cacert "$PVE_CA" --max-time 20 \
			--request "$1" "https://10.0.10.10:8006/api2/json$2"
}

remote_inputs() {
	local keys="$TOFU_REPO/private/ansible/inventory/group_vars/all/ssh.yaml"
	# The operator's public keys: a plain list in the private inventory, the
	# same one the hosts receive. Read without a YAML library, strictly: a
	# list item that is not one public key on one line stops the command,
	# because a key dropped here is missing in the container for good (the
	# key list is written at creation only).
	TF_VAR_ssh_public_keys=$(
		python3 - "$keys" <<'PY'
import json
import re
import sys

ITEM = re.compile(r"^\s+-\s")
KEY = re.compile(
    r"^\s+-\s+(?:"
    r"'((?:ssh-|ecdsa-|sk-)\S+ \S+(?: [^'\"#]*)?)'"
    r"|\"((?:ssh-|ecdsa-|sk-)\S+ \S+(?: [^'\"#]*)?)\""
    r"|((?:ssh-|ecdsa-|sk-)\S+ \S+(?: [^'\"#]*?)?)"
    r")\s*(?:\s#.*)?$"
)
keys, inside = [], False
for number, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if re.match(r"^openwrt_ssh_authorized_keys:\s*(?:#.*)?$", line):
        inside = True
        continue
    if not inside or not line.strip() or line.lstrip().startswith("#"):
        continue
    if not ITEM.match(line):
        break
    m = KEY.match(line.rstrip("\n"))
    if not m:
        sys.exit(f"line {number} of the key list: a list item that is not one public key on one line")
    keys.append(next(g for g in m.groups() if g is not None).strip())
if len(keys) < 2:
    sys.exit("fewer than two public keys found in the private inventory")
print(f"{len(keys)} public keys read from the private inventory", file=sys.stderr)
print(json.dumps(keys))
PY
	)
	export TF_VAR_ssh_public_keys
}

remote_guards() { # <tofu arguments...>
	case "$1" in
	destroy)
		echo "refused: a remote-access container is rebuilt by its runbook only (docs/runbooks/rebuild-remote1.md)" >&2
		exit 2
		;;
	plan | apply)
		local a listed free
		for a in "$@"; do
			case "$a" in
			-destroy | --destroy | -destroy=* | --destroy=* | -replace | --replace | -replace=* | --replace=*)
				echo "refused: -destroy and -replace are not used on this root (docs/runbooks/rebuild-remote1.md)" >&2
				exit 2
				;;
			esac
		done
		if listed=$(tofu state list 2>/dev/null) && grep -qxF "$REMOTE_ADDRESS" <<<"$listed"; then
			# The guest is this root's own. Without its block in the
			# configuration a plan would stop it and try to delete it;
			# prevent_destroy is gone with the block.
			grep -q '^module "remote1" {' "$TOFU_ROOT_DIR/main.tf" || {
				echo "refused: the state holds remote1 and main.tf no longer declares it; a plan would stop and try to delete the container (docs/runbooks/rebuild-remote1.md)" >&2
				exit 2
			}
		else
			free=$(pve_api GET "/cluster/nextid?vmid=$REMOTE_VMID" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"])') || free=''
			[ "$free" = "$REMOTE_VMID" ] || {
				echo "guest id $REMOTE_VMID is taken or could not be checked, and it is not in this root's state (or the state could not be read): the provider would adopt the guest that holds it. Nothing was planned (docs/runbooks/rebuild-remote1.md, 'The guest exists and the state does not hold it')." >&2
				exit 1
			}
		fi
		;;
	esac
}

case "$TOFU_ROOT" in
pve) proxmox_credentials ;;
remote)
	proxmox_credentials
	remote_inputs
	;;
tailscale) tailscale_credentials ;;
esac

eval "set -- $TOFU_ARGS"
cd "$TOFU_ROOT_DIR"

if [ "$TOFU_ROOT" = remote ]; then remote_guards "$@"; fi

if [ "$TOFU_ROOT" = tailscale ]; then
	case "$1" in
	plan | apply) tailnet_policy_check ;;
	esac
fi

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
	# Not exec'd, here and below: the trap above has to run afterwards.
	tofu init -backend-config="$TOFU_BACKEND" -backend-config="key=$STATE_KEY" "$@"
	;;
apply | destroy | import | state | taint | untaint | refresh)
	# Anything here may have changed the state, even when it fails half-way.
	rc=0
	tofu "$@" || rc=$?
	if [ "$TOFU_ROOT" = remote ] && [ "$1" = apply ]; then
		# Without the secrets of this environment: the check needs the
		# operator's SSH agent and nothing else.
		pin=0
		env -i HOME="$HOME" PATH="$PATH" SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}" bash "$TOFU_REPO/scripts/tofu/template-pin.sh" || pin=$?
		case "$pin" in
		0) ;;
		3)
			echo "the template could not be checked after the apply; nothing says it changed. Before the container is started, run: bash scripts/tofu/template-pin.sh" >&2
			rc=1
			;;
		*)
			echo "the template differs from its pin after the apply: do not use a container created by this apply; rebuild it once the hypervisor play has restored the template" >&2
			rc=1
			;;
		esac
		# A creation that fails half-way removes the guest's firewall file on
		# the hypervisor, and a second apply then succeeds without it.
		if [ "$rc" -eq 0 ]; then
			fw=$(pve_api GET "/nodes/pve1/lxc/$REMOTE_VMID/firewall/options" | python3 -c 'import json, sys; print((json.load(sys.stdin).get("data") or {}).get("enable", ""))') || fw=''
			[ "$fw" = 1 ] || {
				echo "the hypervisor's firewall file for guest $REMOTE_VMID is missing or switched off: run 'just pve-apply' and 'just test-remote' before any start" >&2
				rc=1
			}
		fi
	fi
	case "$1:${2:-}" in
	state:list | state:show | state:pull) ;;
	*) copy_state ;;
	esac
	exit "$rc"
	;;
*)
	tofu "$@"
	;;
esac
