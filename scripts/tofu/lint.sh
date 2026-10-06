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
for root in infrastructure/opentofu/roots/*/; do
	(cd "$root" && tofu init -backend=false -input=false >/dev/null && tofu validate)
done
