# Security

This file is the entry point. The full model, with its reasoning, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 15.

## Model in brief

- **Default deny at four layers:** router zones, the hypervisor firewall, the Talos host firewall, and a cluster-wide Cilium policy. Each is enforced from the phase that introduces it.
- **No inbound path from the internet.** The ISP uses carrier-grade NAT. Management interfaces are never published.
- **Identity:** Authentik with MFA for everything that runs on the platform. The systems underneath it (hypervisor, backup server, router, cloud accounts) keep independent, MFA-protected identities.
- **Secrets:** SOPS and age for bootstrap material, OpenBao at runtime, External Secrets Operator for delivery. No plaintext secret in Git, CI or OpenTofu state. No ciphertext in this public repository.
- **Privileged credentials stay on the operator workstation.** None enters the cluster or CI.
- **Backups** are encrypted by their producer before they leave the host, and producers hold credentials that cannot destroy history.

## Rules for this repository

1. Never commit a secret, even encrypted. Encrypted files belong in the private companion repository.
2. Never commit an identifier: MAC address, e-mail address, network name, serial number.
3. Pin every version. No `latest` tags, and GitHub Actions are pinned by commit SHA.
4. Every exception to the model is recorded with an ID, a reason, and a mitigation or removal task.

The pre-commit hooks and CI enforce rules 1 to 3: Gitleaks over the full history, the public-tree policy test, Trivy, Checkov and Semgrep.

## Exceptions register

The register is the table in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 15, IDs X1 to X24. It moves to `docs/security/exceptions.md` when the first component is deployed.

## Secrets register and rotation

Custody and rotation for every class of secret are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 9. The per-secret register, `docs/security/secrets-register.md`, is created with the first secret.

## Reporting a problem

This is a personal homelab. If you find a secret or an identifier in this repository, please open a GitHub security advisory on the repository instead of a public issue.
