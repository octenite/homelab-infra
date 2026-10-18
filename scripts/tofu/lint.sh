#!/bin/bash
# OpenTofu: formatting and validation of every root, without a backend.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"

# A backend override is a tool of the offline runbook
# (docs/runbooks/tofu-offline.md). Committed, it would point every later run
# at a local file instead of the state bucket.
overrides=$(git ls-files -co --exclude-standard -- infrastructure/opentofu | grep -E '(^|/)(override|[^/]*_override)\.tf(\.json)?$' || true)
if [ -n "$overrides" ]; then
	echo "tofu-lint: a backend override is present; it must never be committed (docs/runbooks/tofu-offline.md, part B removes it):" >&2
	printf '  %s\n' "$overrides" >&2
	exit 1
fi

tofu fmt -check -recursive infrastructure/opentofu

# Guests are created through the modules only: their variables carry the
# placement rule (which pool, which VLAN). A root that declared a guest
# directly would escape it.
stray=$(grep -rnE --include='*.tf' --include='*.tofu' 'resource[[:space:]]+"proxmox_' infrastructure/opentofu/roots || true)
if [ -n "$stray" ]; then
	echo "tofu-lint: a root declares a Proxmox resource directly; guests go through infrastructure/opentofu/modules:" >&2
	printf '  %s\n' "$stray" >&2
	exit 1
fi

# One pin for the container template: the hypervisor play and the OpenTofu
# root must name the same file and the same checksum.
pin=infrastructure/opentofu/roots/remote/template.auto.tfvars.json
if [ -f "$pin" ]; then
	read -r tfile tsum < <(python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(d["template_file"], d["template_sha512"])' "$pin")
	vars=infrastructure/ansible/playbooks/group_vars/proxmox.yaml
	if ! grep -qF -- "- file: $tfile" "$vars" || ! grep -qF -- "sha512: $tsum" "$vars"; then
		echo "tofu-lint: $pin and pve_ct_templates in $vars name different templates" >&2
		exit 1
	fi
fi

# One guest id and one address for remote1: the root, the wrapper's guard,
# the hypervisor play (its firewall file is named after the id) and the test
# must agree.
root=infrastructure/opentofu/roots/remote/main.tf
if [ -f "$root" ]; then
	id=$(sed -n 's/^[[:space:]]*vm_id[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$root")
	addr=$(sed -n 's/^[[:space:]]*ipv4_address[[:space:]]*=[[:space:]]*"\([0-9.]*\)\/24"[[:space:]]*$/\1/p' "$root")
	vars=infrastructure/ansible/playbooks/group_vars/proxmox.yaml
	if ! [[ $id =~ ^[0-9]+$ && $addr =~ ^[0-9.]+$ ]] ||
		! grep -qx "REMOTE_VMID=$id" scripts/tofu/child.sh ||
		! grep -qx "VMID=$id" scripts/tests/remote.sh ||
		! grep -qx "ADDR=$addr" scripts/tests/remote.sh ||
		! grep -qx "TUNNEL=$addr" scripts/ops/away-check.sh ||
		! grep -qx "VMID=$id" scripts/node2/travel.sh ||
		! grep -qF "pct status $id'" scripts/tests/travel-guards.sh ||
		! grep -qx "VMID=$id" scripts/tests/travel-outside.sh ||
		! grep -qx "ADDR=$addr" scripts/tests/travel-outside.sh ||
		! grep -qx "VMID=$id" scripts/ops/remote-memory.sh ||
		! grep -qF "\$TunnelSource = '$addr'" scripts/node2/travel.ps1 ||
		! grep -qxE "[[:space:]]*- vmid: $id" "$vars" ||
		! grep -qx "pve_remote_admin: $addr" "$vars"; then
		echo "tofu-lint: guest id or address of remote1 differ between $root, scripts/tofu/child.sh, scripts/tests/remote.sh, scripts/ops/away-check.sh, scripts/node2/travel.sh, scripts/node2/travel.ps1, scripts/tests/travel-guards.sh, scripts/tests/travel-outside.sh, scripts/ops/remote-memory.sh and $vars" >&2
		exit 1
	fi
fi

for root in infrastructure/opentofu/roots/*/; do
	(
		cd "$root"
		tofu init -backend=false -input=false >/dev/null
		tofu validate
		if compgen -G 'tests/*.tftest.hcl' >/dev/null; then
			# Dummies: a test never reads or writes a state.
			TF_VAR_state_passphrase=not-a-secret-test-only \
				TF_VAR_state_passphrase_previous=not-a-secret-test-only \
				tofu test -no-color
		fi
	)
done

# Configurations that `tofu validate` must refuse, and for the right reason:
# the placement rule. (Not under a "tests" path: Renovate skips those, and
# the provider pin in a fixture has to move with the module's.)
for bad in infrastructure/opentofu/refused/*/; do
	[ -d "$bad" ] || continue
	if out=$(cd "$bad" && tofu init -backend=false -input=false >/dev/null && tofu validate -no-color 2>&1); then
		echo "tofu-lint: $bad validated, but it must be refused" >&2
		exit 1
	fi
	if ! grep -q 'Invalid value for variable' <<<"$out" || ! grep -q 'var\.placement' <<<"$out"; then
		echo "tofu-lint: $bad failed for another reason than the placement rule:" >&2
		printf '%s\n' "$out" >&2
		exit 1
	fi
	echo "refused as it must be: $bad"
done
