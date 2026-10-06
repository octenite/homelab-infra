#!/bin/bash
# OpenTofu: formatting and validation of every root, without a backend.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
tofu fmt -check -recursive infrastructure/opentofu
for root in infrastructure/opentofu/roots/*/; do
	(cd "$root" && tofu init -backend=false -input=false >/dev/null && tofu validate)
done
