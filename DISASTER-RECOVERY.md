# Disaster recovery

Status: **designed, not yet tested.** Nothing below counts as verified until the drill in Phase 15 has run and its timings are recorded here. A backup that has never been restored is not a backup.

The question this document must answer: if the Proxmox server is completely destroyed, how is the environment rebuilt?

## Procedure

The designed procedure is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 13. In outline:

1. New hardware, firmware settings, network cable.
2. Boot the unattended Proxmox installer.
3. Ansible configures the host.
4. OpenTofu creates the Talos VMs and bootstraps Kubernetes.
5. Cilium, the policy baseline and Argo CD are bootstrapped.
6. Argo CD converges the platform core. OpenBao is restored from its snapshot.
7. Stateful services and applications are restored in a dedicated recovery mode, so restored data is never overwritten by freshly started workloads.
8. Verification, then normal operation.

Each runbook under `docs/runbooks/` is written with the phase that introduces the dataset it restores.

## Manual steps that remain

By design: obtaining hardware and setting its firmware, booting the installer, committing re-issued tokens, six `just` commands, and validation. The list is revised after every drill.

## What recovery depends on

| Needed | Where it lives |
|---|---|
| This repository and the private companion repository | GitHub, local clones, quarterly bundles off-site |
| The recovery age key and recovery SSH key | The owner's password manager and sealed paper copies |
| Backups | The backup server on the workstation, and off-site object storage |
| Accounts that do not depend on the cluster | GitHub, Cloudflare, the storage provider, the password manager, each with its own MFA |

## Targets

Until measured: platform back in one working day, data in two. Recovery point 24 hours for volumes, 6 hours for the identity database and the secrets store.

## Drill log

| Date | Scenario | Result | Time taken |
|---|---|---|---|
| - | None run yet | - | - |
