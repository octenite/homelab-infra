# Security

This file is the entry point. The full model, with its reasoning, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 15.

Checked against the code on 2026-10-07. Phases 0, 1, 2 and 4 are closed. Phase 3 (hypervisor and backup server) is built, and its gate is open. The cluster and everything on it are not built.

## Model in brief

| Control | Design | Built on 2026-10-07 |
|---|---|---|
| Default deny at four layers | router zones, the hypervisor firewall, the Talos host firewall, a cluster-wide Cilium policy; each enforced from the phase that introduces it | router zones (Phase 2) and the hypervisor firewall (Phase 3). The Talos and Cilium layers arrive in Phase 6 |
| No inbound path from the internet | the ISP uses carrier-grade NAT; management interfaces are never published | as designed |
| Identity | Authentik with MFA for everything that runs on the platform; the systems underneath it keep independent identities with a second factor | hypervisor: both password accounts require TOTP. Backup server: `root@pam` has a password only (open item 1). Router and access points: SSH key only; LuCI listens on the loopback address and is reached inside the SSH session, behind a password. Authentik arrives in Phase 11 |
| Secrets | SOPS and age for bootstrap material, OpenBao at runtime, External Secrets Operator for delivery; no plaintext secret in Git, CI or OpenTofu state; no ciphertext in this public repository | SOPS and age, in the private companion repository. OpenTofu state encryption is enforced in the code, and the state round trip against the bucket passed on 2026-10-07. OpenBao arrives in Phase 8 |
| Privileged credentials stay on the operator workstation | none enters the cluster or CI | as designed. The operator's keys are stored passphrase-encrypted and are open only during a session of at most 12 hours (`just session-start`, `just session-end`) |
| Backups | encrypted by their producer before they leave the host; producers hold credentials that cannot destroy history | the hypervisor's configuration backup is client-side encrypted, and its token holds `DatastoreBackup` only. No off-site copy exists yet |

## Rules for this repository

1. Never commit a secret, even encrypted. Encrypted files belong in the private companion repository.
2. Never commit an identifier: MAC address, e-mail address, network name, serial number.
3. Pin every version. No `latest` tags, and GitHub Actions are pinned by commit SHA.
4. Every exception to the model is recorded with an ID, a reason, and a mitigation or removal task.

What enforces them:

| Check | Where it runs | Covers |
|---|---|---|
| Gitleaks | pre-commit hook on staged changes; `just secrets` in CI on the full history and the working tree | rule 1 |
| Public-tree policy (`just policy`, `policy/public-tree.sh`) | pre-commit hook and `just lint` in CI | rule 1: secret-bearing file names, ciphertext and key material by content. Rule 2: MAC addresses in four spellings and e-mail addresses |
| Trivy, Checkov, Semgrep (`just scan`) | CI | misconfiguration, secrets and vulnerabilities at HIGH and CRITICAL |

The policy test is a net for accidents, not a proof. Network names and serial numbers have no pattern, and rule 3 has no automated check yet (backlog B7). Review remains the control for those.

## Fence test

The backup server VM runs on the operator workstation. The paths to it are fenced by Windows Firewall block rules, Hyper-V port ACLs and nftables in the guest (exceptions E10 and E14 in section 6 of the architecture, X25 and X26 in section 15).

```sh
just test-fences
```

The test opens connections and sends pings from the hypervisor, the router, WSL and the backup server. It changes nothing. It fails when a single probe disagrees with the expectation, and it prints whether the management window is open. The probes from the backup server run only while the window is open.

Status: a passing run is not recorded yet. The last recorded run, made before the current rules were applied on the workstation, had 12 probes disagree. See open item 3.

## Exceptions register

The register is the table in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 15, IDs X1 to X26. Firewall exceptions E1 to E14 are in section 6. Exceptions added or changed by Phase 3:

| ID | Exception | State |
|---|---|---|
| X2 | Install images embed a password hash | images are removed after use by the scripts and the host role; the disaster-recovery image on the workstation, and a stick written from it, are deleted by hand |
| X7 | Backup server on a laptop under Hyper-V, Generation 1, no Secure Boot, internet egress not restricted | accepted |
| X18 | Backup server not federated to the identity provider | its second factor is open (item 1) |
| X23 | No disk encryption on the workstation | accepted by the owner; hardening open (item 2) |
| X25 | Shared service process on the workstation makes allow rules ineffective for the forwarded ports; block rules compensate | passing fence test open (item 3) |
| X26 | Management window: a port forward to the backup server's SSH, opened by hand with `pbs-vm.ps1 -Manage` and closed by a plain run | accepted; `just test-fences` shows which state is live |

## Open items

| # | Item | Closed by |
|---|---|---|
| 1 | The backup server's `root@pam` has no second factor (X18, backlog B24) | the owner enrols TOTP in the backup server's web interface |
| 2 | The workstation's disks are not encrypted (X23). Nothing readable is stored in a file there, and since 2026-10-07 `scripts/node2/workstation.ps1` keeps the session key off the disk: no WSL swap, an encrypted pagefile, no hibernation. A stolen disk still yields the backup VM's system disk and the ciphertext | disk encryption removes the exception |
| 3 | The fence test (X25, X26) passed on 2026-10-07 with the management window open and, after the restart, with it closed. Nothing runs it on a schedule | run `just test-fences` after every change to the workstation's network or firewall, and after every run of `pbs-vm.ps1` |
| 4 | The root cause of X25 was removed on 2026-10-07: `scripts/node2/workstation.ps1` keeps Windows on one service per process. A tuning tool or a Windows change can raise the threshold again | the script reports and corrects it on every run; the block rules stay as the second layer |
| 6 | The healthchecks ping URL appeared once in a session transcript | a new URL, stored with `just secret-set` |
| 7 | No off-site copy of the backups exists (B25) | the off-site buckets, with the datasets of the later phases |
| 8 | The backup server's traffic to the internet is not restricted (X7, B33) | an allow-list, or the owner's acceptance as it stands |

## Secrets register and rotation

Custody and rotation for every class of secret are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 9. The per-secret register is [docs/security/secrets-register.md](docs/security/secrets-register.md).

## Reporting a problem

This is a personal homelab. If you find a secret or an identifier in this repository, please open a GitHub security advisory on the repository instead of a public issue.
