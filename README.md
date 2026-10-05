# homelab-infra

Infrastructure as code for a small, production-style homelab platform: one Proxmox VE host, a two-VM Talos Linux Kubernetes cluster, GitOps with Argo CD, centralized secrets and identity, default-deny networking, monitoring, and tested backups.

Nothing here is physically highly available. There is one host, one disk and one uplink. The answer to failure is a rehearsed rebuild from this repository plus a restore from backups.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Discovery, design, owner decisions, device inventories | Complete |
| 1 | Repositories, standards, pinned tooling, secret handling, CI | Complete |
| 2 | Router segmentation: VLANs, firewall matrix, DNS, DHCP, NTP | Done, see [the record](docs/phases/phase-2.md) |
| 4 | Access points: trunks, guest and IoT networks, hardening | Next, see [the plan](docs/phases/phase-4-plan.md) (moved ahead of Phase 3 by the owner) |
| 3, 5 to 15 | Hypervisor, cluster, platform, applications, recovery drill | Not started |

Gate records are in [docs/phases/](docs/phases/). No phase starts before the previous gate is recorded.

## Where to read

| Document | Content |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The target design: topology, resource budget, network policy matrix, secrets, identity, backups, recovery, phases, decision log |
| [docs/INITIAL-ASSESSMENT.md](docs/INITIAL-ASSESSMENT.md) | What exists today, measured |
| [docs/adr/](docs/adr/) | Architecture decision records |
| [SECURITY.md](SECURITY.md) | Security model and exceptions |
| [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) | Rebuild procedure and its test status |
| [CLAUDE.md](CLAUDE.md) | Project brief and working rules |

## Two repositories

This repository is public and holds code, manifests and documentation. It contains no ciphertext and no identifiers such as MAC addresses or e-mail addresses. A CI policy test enforces that.

Encrypted secrets and the identifying inventory live in a private companion repository, mounted as the Git submodule `private/` and pinned by commit. CI never checks it out, and Argo CD never needs it.

## Working on this repository

Work from Linux. On Windows that means WSL2: Ansible needs it, and the Git hooks are installed there.

```sh
# once: install mise (https://mise.jdx.dev) and activate it in ~/.bashrc:
#   export PATH="$HOME/.local/bin:$PATH"
#   eval "$(mise activate bash)"
# then, in a new terminal, inside the repository:
mise trust
just setup      # pinned tools, Git hooks, submodule
just lint       # fast checks: YAML, shell, workflows, public-tree policy
just secrets    # secret scan of history and working tree
```

Tool versions are pinned in `mise.toml` and maintained by Renovate. `just` with no arguments lists every recipe.

## Change flow

Branch, pull request, CI, merge. Kubernetes changes are then applied by Argo CD. Host and network changes are applied by the operator from the workstation with `just` recipes, because no hosted runner can or should reach the lab. `kubectl apply` is for diagnostics and the documented bootstrap only.
