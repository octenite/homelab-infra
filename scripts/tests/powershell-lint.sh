#!/bin/bash
# Parse every PowerShell script and run PSScriptAnalyzer on it. The scripts
# manage firewall rules, port ACLs and disks on the workstation; without this
# nothing would look at them before an elevated prompt runs them.
#
# Needs pwsh (PowerShell 7). GitHub's runners have it; a workstation without
# it gets a notice and exit 0, because the same check runs in CI. The scripts
# target Windows PowerShell 5.1, so this is a parse and static-analysis gate,
# not a run.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
if ! command -v pwsh >/dev/null 2>&1; then
	echo "pwsh not installed: PowerShell checks skipped here (CI runs them)"
	exit 0
fi
pwsh -NoProfile -NonInteractive -File scripts/tests/powershell-lint.ps1
