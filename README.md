# homelab-infra

Infrastructure as code for a small, production-style homelab platform: one Proxmox VE host, a two-VM Talos Linux Kubernetes cluster, GitOps with Argo CD, centralized secrets and identity, default-deny networking, monitoring, and tested backups.

Nothing here is physically highly available. There is one host, one disk and one uplink. The answer to failure is a rehearsed rebuild from this repository plus a restore from backups.

## Status

On 2026-10-07: Phases 0, 1, 2 and 4 are closed. Phase 3 is built and reviewed, and its gate is open. The cluster (Phase 5 onwards) is not started.

| Phase | Scope | State |
|---|---|---|
| 0 | Discovery, design, owner decisions, device inventories | Closed |
| 1 | Repositories, standards, pinned tooling, secret handling, CI | Closed |
| 2 | Router segmentation: VLANs, firewall matrix, DNS, DHCP, NTP | Closed, see [the record](docs/phases/phase-2.md) |
| 4 | Access points: trunks, guest and IoT networks, hardening (ran before Phase 3 by the owner's decision) | Closed, see [the record](docs/phases/phase-4.md) |
| 3 | Hypervisor: unattended reinstall, hardening, exporters, access roles and tokens, backup server VM, nightly host backup, OpenTofu root | Built and reviewed; gate open, see [the record](docs/phases/phase-3.md) |
| 5 to 15 | Cluster, platform, applications, recovery drill | Not started |

What keeps the Phase 3 gate open (items G1 and G3 of the record; G2, G4, G5 and G6 closed on 2026-10-07):

| Item | Closed by |
|---|---|
| Deny test of the backup path's fences | passed with the management window open (51 of 51 probes). Still owed: the owner runs `scripts\node2\workstation.ps1` in an elevated PowerShell and restarts Windows, then closes the window with a plain run of `scripts\node2\pbs-vm.ps1`; `just test-fences` must pass again |
| 24-hour soak of the direct 2.5 GbE link | the result after 2026-10-07 21:10 |

Open in Phase 3 without gating it:

| Item | Closed by |
|---|---|
| Second factor for `root@pam` on the backup server | the owner enrols it, before Phase 5 puts guest backups on the server |
| Owner decisions | the svchost split threshold on the workstation; swap, pagefile and hibernation hardening (exception X23) |

Deferred to Phase 5: the deny test from the servers network, which has no guest yet.

Gate records are in [docs/phases/](docs/phases/). No phase starts before the previous gate is recorded.

## Where to read

| Document | Content |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The design and what is built of it: topology, resource budget, network policy matrix, secrets, identity, backups, recovery, phases, decision log |
| [docs/INITIAL-ASSESSMENT.md](docs/INITIAL-ASSESSMENT.md) | What existed before the work started, measured |
| [docs/adr/](docs/adr/) | Architecture decision records |
| [docs/components/](docs/components/) | One document per component: router and access points, hypervisor, backup server |
| [docs/runbooks/](docs/runbooks/) | Operating and restore procedures |
| [docs/security/secrets-register.md](docs/security/secrets-register.md) | Every secret: where it lives and how it is rotated |
| [docs/backlog.md](docs/backlog.md) | Open items outside the current phase |
| [SECURITY.md](SECURITY.md) | Security model, exceptions and open items |
| [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md) | Rebuild procedure and its test status |
| [CLAUDE.md](CLAUDE.md) | Project brief and working rules |

## Two repositories

This repository is public and holds code, manifests and documentation. It contains no ciphertext and no identifiers such as MAC addresses or e-mail addresses. A CI policy test enforces that for the patterns it knows.

Encrypted secrets and the identifying inventory live in a private companion repository, mounted as the Git submodule `private/` and pinned by commit. CI never checks it out, and Argo CD never needs it.

The pin can be older than the newest secrets. All work and every recovery use the private repository's `main` branch. `just setup` switches to it, and `just private-status` reports whether it is on `main`, clean and in step with GitHub.

## Working on this repository

Work from Linux. On Windows that means WSL2: Ansible needs it, and the Git hooks are installed there. The one exception is the backup server VM, which is managed from an elevated PowerShell with `scripts\node2\pbs-vm.ps1`.

```sh
# once: install mise (https://mise.jdx.dev) and activate it in ~/.bashrc:
#   export PATH="$HOME/.local/bin:$PATH"
#   eval "$(mise activate bash)"
# then, in a new terminal, inside the repository:
mise trust
just setup      # pinned tools, Git hooks, the private repository on its main branch
just lint       # fast checks: YAML, shell, workflows, public-tree policy, templates, Ansible, OpenTofu
just secrets    # secret scan of history and working tree
```

`just setup` does not fetch the pinned Ansible collections. `just lint` does, and so does `just ansible-deps` alone. A fresh clone needs one of the two before the first play.

Tool versions are pinned in `mise.toml` and maintained by Renovate. `just` with no arguments lists every recipe.

## Operating the lab

Every recipe that touches a host needs an operator session. A session holds the SSH key and the decrypted age key in memory and ends by itself after 12 hours.

| Task | Command |
|---|---|
| Open, check and close the session | `just session-start`, `just session-status`, `just session-end` |
| Check the private repository before writing secrets | `just private-status` |
| Compare the network devices with Git (read-only) | `just openwrt-check openwrt` (without a target: the router only) |
| Apply Git to a network device, guarded by a revert | `just openwrt-apply <target>` |
| Configure the hypervisor | `just pve-apply` |
| Configure the backup server (needs the management window: `pbs-vm.ps1 -Manage`) | `just pbs-apply` |
| Deny test of the backup path's fences | `just test-fences` |
| OpenTofu for one root (works once the state backend is initialised) | `just tofu pve plan` |
| Read one secret value; store one at a hidden prompt | `just reveal <file> <key>`, `just secret-set <file> <key>` |

Rebuilding the hypervisor is in [docs/runbooks/restore-pve-host.md](docs/runbooks/restore-pve-host.md).

## Change flow

Branch, pull request, CI, merge. Host and network changes are then applied by the operator from the workstation with `just` recipes, because no hosted runner can or should reach the lab. From Phase 7, Kubernetes changes are applied by Argo CD, and `kubectl apply` is for diagnostics and the documented bootstrap only.
