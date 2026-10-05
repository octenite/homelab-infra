# ADR-0001: Platform technology stack

- Status: Accepted by the owner on 2026-10-05 (recommended defaults; answers in `../ARCHITECTURE.md` section 20)
- Date: 2026-10-05
- Deciders: repository owner
- Supersedes: none

## Context

The homelab must behave like a small production platform: infrastructure as code, GitOps, centralized identity and secrets, default-deny networking, monitoring, tested backups and a documented rebuild. `CLAUDE.md` section 3 suggests a stack and asks for it to be challenged.

Three facts from discovery and research bound every choice:

1. **One small, old host.** Node 1 is an Intel i5-3570 with 4 threads and 16 GB of RAM that cannot be expanded. It has one 256 GB consumer SATA SSD. It supports the x86-64-v2 instruction level only.
2. **No inbound connectivity.** The ISP uses carrier-grade NAT, and no IPv6 was observed. Nothing in the lab can listen on the internet.
3. **One operator, one intermittent second machine.** Node 2 is a Windows laptop that sleeps and leaves the house. It can hold tooling and backups. It cannot hold a control-plane role.

Versions below are the major.minor baseline verified on 2026-10-05. Exact pins live in Git and are maintained by Renovate. Sources are in `../research/2026-10-05-platform-research.md`.

## Decision drivers

- Fit in 16 GB with measured headroom, and say so honestly where the fit is tight.
- Prefer mature, widely adopted, declaratively configured tools.
- No privileged credential inside the cluster or in CI.
- Every backup encrypted before it leaves the host.
- Day-to-day operation must not depend on a service outside the house.
- No claim of high availability that one physical host cannot honour.

## Decision

### Infrastructure

| Function | Choice | Rejected alternatives | Reason |
|---|---|---|---|
| Hypervisor | Proxmox VE 9.2, unattended install from an answer file | Bare-metal Talos; plain KVM | The host needs VM backups, a storage API for Kubernetes volumes, and a second machine boundary between the control plane and workloads |
| Host filesystem | ext4 with an LVM-thin pool | ZFS on a single disk | ZFS would cost about 1 GiB of RAM for its cache and more SSD wear. On one disk it detects corruption but cannot repair it |
| Provisioning | OpenTofu 1.13 with the `bpg/proxmox` 0.115 and `siderolabs/talos` 0.12 providers | Telmate provider; Terraform | Telmate has no stable release for Proxmox 9. OpenTofu has native state encryption |
| Host configuration | Ansible for Proxmox, the backup server and OpenWrt (`community.openwrt` collection) | Shell scripts; the archived `gekmihesg` role; a dormant OpenWrt Terraform provider | The only maintained declarative path for OpenWrt; idempotent |
| State backend | Backblaze B2, client-side encrypted | Local state; Cloudflare R2 | Same provider as the backups; versioned bucket; state holds rendered Talos configuration, so encryption is mandatory |

### Kubernetes

| Function | Choice | Rejected alternatives | Reason |
|---|---|---|---|
| Node OS | Talos Linux 1.14, configured only through its API | k3s on Debian; kubeadm | Immutable, no SSH, declarative; required by `CLAUDE.md` |
| Kubernetes version | 1.36 | 1.37 (the Talos default) | cert-manager, External Secrets, CloudNativePG and Cilium had not declared support for 1.37 |
| Cluster shape | 1 control-plane VM (3 GiB) and 1 worker VM (9 GiB) | Single node; 1 control plane and 2 workers; 3 control planes | Isolates etcd from application memory pressure. Two workers cannot deliver rolling upgrades on this host. Three control planes are unaffordable and would be logical redundancy only. The shape is a module variable and can be changed with one apply |
| CNI | Cilium 1.20, kube-proxy replacement, load-balancer addresses announced on layer 2 | Flannel; Calico | Network policy with DNS-aware egress; required by `CLAUDE.md` |
| Network policy | Cluster-wide default-deny enforced from the first workload | Audit mode during roll-out | Audit mode is not available per namespace and would leave secrets and identity unprotected for several phases |
| Gateway API | Traefik 3.7, one instance with a household and an admin listener | Cilium Gateway; Envoy Gateway | Smallest footprint with ForwardAuth support. Cilium's gateway shares one identity for all gateways, so policy cannot separate internal from external |
| Storage | Proxmox CSI 0.20 on the thin pool | Longhorn; Rook-Ceph; democratic-csi | Replication onto the same single SSD adds cost and no protection. democratic-csi would put a root-equivalent hypervisor credential in the cluster |

### GitOps, CI and automation

| Function | Choice | Rejected alternatives | Reason |
|---|---|---|---|
| Deployment | Argo CD 3.5; ApplicationSets over Git directories | Flux; push-based deploys from CI | Required by `CLAUDE.md`. Hosted CI runners cannot reach a lab behind carrier-grade NAT |
| Rendering | Kustomize inflating pinned Helm charts | Argo CD multi-source Helm applications | One render path, so CI validates exactly what Argo CD applies |
| CI | GitHub Actions: lint, validate, policy tests, Gitleaks, Trivy, Checkov, Semgrep | - | Required by `CLAUDE.md`; pull-request jobs carry no secrets |
| Dependency updates | Hosted Renovate; automerge for tooling only | Self-hosted Renovate; automerge for everything | Nothing to host. No unreviewed change can reach the cluster |
| Tool pinning | mise, just, pre-commit | Ad hoc installs | The same pinned tools locally and in CI |
| Images | GitHub Container Registry, pinned by digest | Argo CD Image Updater | Renovate already turns digest changes into reviewed pull requests |

### Secrets and identity

| Function | Choice | Rejected alternatives | Reason |
|---|---|---|---|
| Secrets in Git | SOPS 3.13 with age 1.3, kept in a private companion repository | SOPS files in the public repository; Sealed Secrets | Ciphertext in a public history can never be withdrawn, so one later key leak would expose everything ever committed |
| Runtime secrets | OpenBao 2.7, one Raft node, static-key auto-unseal | HashiCorp Vault; manual Shamir unseal | Open licence. The host has no UPS, so unsealing must work unattended after a power cut |
| Delivery | External Secrets Operator 2.11 with its stable Vault provider | Argo CD decrypting SOPS (KSOPS) | Argo CD's own guidance is to keep decryption out of the repo-server; no age key enters the cluster |
| Identity provider | Authentik 2026.8 on its own PostgreSQL | Keycloak; Authelia; Pocket ID; Zitadel | Keycloak needs roughly 2 to 3 times the memory. Authelia has no user management. Pocket ID is passkey-only and has no forward-auth. Pocket ID is the recorded fallback if memory forces it |
| Hypervisor and backup logins | Local accounts with MFA; Proxmox gets a read-only OIDC realm | Full OIDC federation | An identity provider that runs on the cluster must not be able to create a hypervisor or backup administrator |

### Data, observability and backup

| Function | Choice | Rejected alternatives | Reason |
|---|---|---|---|
| PostgreSQL | CloudNativePG 1.30, one small cluster per trust group | A shared instance | Restoring one application must not roll back identity |
| Metrics and alerts | kube-prometheus-stack 91, Alertmanager to Telegram, a dead-man's switch at healthchecks.io | VictoriaMetrics | Required by `CLAUDE.md`. A single host cannot report its own death without an external heartbeat |
| Logs | Loki 3.7 in monolithic mode with Alloy 1.20 | Loki with object storage | Fits the memory budget; logs are an accepted loss and are not backed up |
| VM backups | Proxmox Backup Server 4.2 as a Hyper-V VM on Node 2 | Backup server on Node 1; file dumps to a share | Proxmox advises against running it on the hypervisor it protects, and Node 1 has no memory for it |
| Volume backups | VolSync 0.16 with restic | Velero; Kopia | Upstream VolSync has no Kopia mover. Velero duplicates what Git and etcd snapshots already provide and needs a privileged agent |
| Database backups | Encrypted `pg_dump` through restic | The CloudNativePG Barman plugin | The Barman plugin supports provider-side encryption only, and continuous archiving would tie the identity database to internet availability. The cost is a 6 hour recovery point instead of minutes |
| etcd backups | `talos-backup`, age-encrypted | VM image only | Two independent chains for the cluster state |
| Off-site | Backblaze B2 with Object Lock | Cloudflare R2; Hetzner Storage Box | Versioning and Object Lock, so a compromised producer cannot erase history. R2 has neither |

### Network and exposure

| Function | Choice | Rejected alternatives | Reason |
|---|---|---|---|
| Router and access points | OpenWrt 25.12 on the existing devices | New hardware | The existing devices support VLAN-aware bridging; no purchase is needed |
| Segmentation | VLANs 10 (management), 20 (trusted), 50 (servers), 60 (IoT), 70 (guest); default-deny between zones | Flat network | Required by `CLAUDE.md`. VLAN 40 (DMZ) is reserved but not built, because nothing can be reached from the internet |
| Addressing | The existing 192.168.1.0/24 stays as the trusted VLAN; new VLANs use 10.0.<VLAN>.0/24 | Renumbering everything | No household device changes address |
| TLS | cert-manager 1.21 with Let's Encrypt DNS-01 through Cloudflare | HTTP-01 | The only challenge that works without inbound access, and the only one that issues wildcards |
| Public exposure | None at first; later Cloudflare Tunnel with Cloudflare Access | Port forwarding (impossible) | Outbound-only; management interfaces are never published |
| Remote administration | None at first; an optional later phase in its own VLAN | Tailscale as the default admin path | Daily administration must not depend on a third party |

## Deviations from the suggested stack

The full table with reasons is in `../ARCHITECTURE.md` section 18. The ones that change behaviour:

- Guard rails first: SOPS, scanning and Renovate move to Phase 1, and the router is segmented before the hypervisor is installed.
- VLAN 40 (DMZ) is reserved, not built.
- Restic only; no Kopia.
- PostgreSQL is backed up by encrypted dumps, not by CloudNativePG's own archiving.
- OIDC is not used "wherever supported": the backup server stays local and Proxmox is read-only through OIDC.
- Two repositories instead of one: public code, private ciphertext.
- No guest disk encryption: the key would sit on the same unencrypted disk, so it would protect nothing here.
- Hubble runs inside the Cilium agent only; no relay and no UI.

## Consequences

Positive:

- The whole platform fits in 12 GiB of guest memory with 1.7 GiB of host headroom, by estimate.
- A destroyed host can be rebuilt from Git, Bitwarden and the off-site copy. The manual steps are listed and counted.
- No privileged hypervisor, router or provisioning credential lives in the cluster or in CI.
- A compromised cluster cannot erase backup history or reach the hypervisor's administration.

Negative:

- Application room is small: about 2.3 GiB practical by estimate, and far less if the platform lands at the top of the researched range. A trigger and an ordered list of levers are agreed in advance.
- Every worker upgrade is an outage of all applications, identity and ingress for several minutes.
- Nothing is physically redundant. One disk failure is a full restore.
- The recovery point for databases is 6 hours for identity and 24 hours for others.
- Several mechanisms are young: OpenBao self-initialisation, the newest Talos provider resources, Cilium layer-2 announcements, scoped ACLs for the storage driver. Each has a phase gate and a named fallback.
- The design depends on free tiers at GitHub, Cloudflare, Mend and healthchecks.io. None of them holds unique data.

## Follow-up ADRs

| ADR | Topic | Due |
|---|---|---|
| 0002 | At-rest encryption: host-level disk encryption on Node 1 against unattended reboot | Phase 3 |
| 0003 | Repository layout: public plus private companion repository | Phase 1 |
| 0004 | Backup and recovery: tools, credentials that cannot destroy history, recovery modes | Phase 3 |
| 0005 | Administrative access: pinned workstation, optional remote access | Phase 2 |
| 0006 | Gateway and exposure model | Phase 10 |

## References

- `../ARCHITECTURE.md`: full design, decision log (section 19), exceptions (section 15)
- `../INITIAL-ASSESSMENT.md`: discovery evidence
- `../research/2026-10-05-platform-research.md`: sourced facts with confidence labels
