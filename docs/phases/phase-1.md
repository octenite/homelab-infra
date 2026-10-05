# Phase 1 gate record: repositories, standards, tooling, CI

Status: **open.** The automated part is done and verified. Three items need the owner.

## Done and verified (2026-10-05)

| Gate item | Evidence | Result |
|---|---|---|
| Public repository | `octenite/homelab-infra`, public | Created and pushed |
| Private companion repository | `octenite/homelab-private`, private, mounted as the submodule `private/` | Created and pushed |
| Commit identity | GitHub no-reply address in the local Git configuration of both repositories | No personal address in history |
| Pinned toolchain | `mise.toml`, `mise.ci.toml`; mise itself installed from its release with a checksum check | Installed in WSL2 |
| Task runner | `justfile`: `lint`, `secrets`, `scan`, `ci`, `setup`, `fmt` | Same recipes locally and in CI |
| Pre-commit hooks | `.pre-commit-config.yaml`: Gitleaks, public-tree policy, yamllint, shellcheck, shfmt, actionlint | Installed; all pass |
| CI | `.github/workflows/ci.yaml`: job `lint` (lint, policy, Gitleaks over full history) and job `scan` (Trivy, Checkov, Semgrep); actions pinned by commit SHA; read-only token; no secrets | Green on `main` |
| A planted secret is blocked locally | A fake private key and a fake token were staged; the commit was refused by the Gitleaks hook | Blocked |
| A planted identifier is blocked locally | A MAC address and an e-mail address were staged; the commit was refused by the policy hook | Blocked |
| A planted secret is blocked in CI | Pull request 1, created through the API so no local hook was bypassed; both jobs failed; closed unmerged | Blocked |
| Branch ruleset on `main` | Pull request required; `lint` and `scan` required; no deletion; no force push | A direct push was refused |
| Repository settings | Secret scanning and push protection on; Dependabot alerts on; private vulnerability reporting on; workflow token read-only by default; merge commits off; branches deleted on merge | Applied |
| Laptop personally owned | Owner statement, 2026-10-05 | Confirmed |
| Lab SSH key is passphrase-protected | An empty-passphrase read of the private key is refused | Confirmed |

## Deviations from the design, with reasons

| Design said | Done instead | Reason |
|---|---|---|
| Semgrep with `--config auto --metrics off` | Named rule packs (`p/default`, `p/secrets`, `p/github-actions`) with metrics off | Semgrep refuses `auto` when metrics are off |
| Every linter in CI from day one | Linters for OpenTofu, Ansible, Helm, Kustomize and Kubernetes manifests arrive with the phase that adds their first file | A pinned tool with nothing to check is an untested pin |
| `mise.lock` | Exact versions in `mise.toml`, no lock file yet | Follow-up below |

## Open: needs the owner

| # | Item | How |
|---|---|---|
| 1 | Create the operator and recovery age keys | `docs/runbooks/bootstrap-keys.md`; then `private/.sops.yaml` is written and the recovery-key-only decryption test is run |
| 2 | Install the hosted Renovate app on `octenite/homelab-infra` | https://github.com/apps/renovate, select only this repository; the configuration is already in `renovate.json5` |
| 3 | GitHub token at rest on the workstation | The GitHub CLI in WSL2 keeps its token in a readable file. On an unencrypted disk that conflicts with exception X23. Options are recorded in the follow-ups |

## Follow-ups

| Item | When |
|---|---|
| Decide how the GitHub token is stored: Windows Git Credential Manager from WSL2, or a fine-grained token limited to the two repositories with a short expiry | Before Phase 2 |
| Add `mise.lock` and the repository setting that requires actions pinned by SHA | With the first Renovate pull request |
| Recovery SSH key (private half in the password manager) | With the age keys |
| X23 verification scan of the WSL home directory for readable key material | After items 1 and 3 |
