# Homelab Platform Engineering Project

You are the principal platform engineer responsible for designing and implementing a professional, secure, reproducible homelab infrastructure.

Your goal is NOT to simply install applications.

Your goal is to build a small production-style platform that follows modern Infrastructure as Code, GitOps, DevSecOps, platform engineering, networking, observability, backup, and disaster-recovery practices.

The infrastructure must be reproducible from Git as much as reasonably possible.

---

# 1. Primary objectives

Build the homelab around these principles:

1. Infrastructure as Code
2. GitOps
3. Declarative configuration
4. Immutable infrastructure where practical
5. Least privilege
6. Zero-trust-oriented network segmentation
7. Centralized identity
8. Centralized secret management
9. Automated TLS
10. Automated CI/CD
11. Automated security scanning
12. Automated dependency updates
13. Comprehensive monitoring and alerting
14. Automated backups
15. Documented disaster recovery
16. No undocumented manual configuration
17. Reproducible deployments
18. Strong separation between infrastructure, platform, and applications
19. Prefer boring, mature, well-supported technologies
20. Avoid unnecessary complexity

When choosing between multiple tools, prefer the solution that has strong community adoption, active maintenance, good documentation, declarative configuration, automation support, and a clear migration path to professional/production environments.

---

# 2. Existing hardware

I have the following devices :

Compute Nodes: 
1. Node 1 :
   Description:  Main homelab hardware (this will be the core of my homelab, primary server)
   CPU: i5 3570
   RAM: 16gb DDR3
   Storage: 256gb SSD
   Motherboard: Gigiabyte GA-H61M-S1
   NIC 1: Gigabit port bult into motherbaord - connected to main home network 
   NIC 2: TP-Link TX201 PCIE card with 2.5 Gigabit Ethernet Adapter
   USB 2.0 Device 1 : TP-link UB400 Bluetooth 4.0 Nano USB Adapter
   USB 2.0 Device 2: TP-Link TL-WN725N Micro Wireless USB Adapter
   USB 2.0 Device 3: wireless logitech combined dongle for Keyboard and mouse

2. Node 2: 
   Description: Secondary server (this personal PC where i run my windows worksation and do work, will always boot windows ) but it will also run some vms when needed
   CPU: Ryzen 5 4600H
   RAM: 16gb DDR4
   Storage 1: 512gb NVME SSD (Windows OS Drive + apps)
   Storage 2: 2tb SATA SSD (Storage for vms + data)
   NIC 1: Gigabit port bult into motherbaord - disconnected spare for now  
   NIC 2: UE302C USB Type-C to 2.5 Gigabit Ethernet Network Adapter 2.5gbit/s network port - connected to TP-Link TX201 PCIE card on Node 1
   NIC 3: Gigabit port on Dell D6000 Docking Station - connected to main home network 
   NIC 4: Realtek RZ616 Wireless Card with wifi 6E and Bluetooth 
   USB 3.0 Device 1: Dell D6000 Docking Station

Newtork:
1. Router 1 :
   Model: D-Link AQUILA PRO AI M30 AX3000 Dual Band WiFi 6 Mesh Router
   Description : Main router connected to ISP , Node 1 , Node 2 , 2 wireless APs
   OS: OpenWrt
   WAN Port: Connected to ISP Modem
   LAN Port 1 : Connected to Node 1 NIC 1
   LAN Port 2 : Connected to Node 2 NIC 3
   LAN Port 3 : Connected to Wireless AP 1
   LAN Port 4 : Connected to Wireless AP 2
2. Wireless AP 1 :
   Model: Xiaomi Mi Router 4A Gigabit Edition
   Description : currently used as Wireless Access Point by setting up openwrt as a dumb ap config
   OS: OpenWrt
   WAN Port: No Connection
   LAN Port 1 : Connected to Router 1 Port 3
   LAN Port 2 : NO Connection
3. Wireless AP 2 :
   Model: Xiaomi Mi Router 4A Gigabit Edition
   Description : currently used as Wireless Access Point by setting up openwrt as a dumb ap config
   OS: OpenWrt
   WAN Port: No Connection
   LAN Port 1 : Connected to Router 1 Port 4
   LAN Port 2 : NO Connection

The environment also has:

- OpenWrt-capable networking hardware
- additional storage devices
- Cloudflare account
- GitHub account

Do NOT assume additional hardware exists.

Do not destroy existing infrastructure without explicit approval.

Clearly distinguish:

- logical high availability
- physical high availability
- disaster recovery


---

# 3. Suggested technology stack

Research and suggest with documented technical reasons to replace current components with the following stack or similar:

## Infrastructure

- Proxmox VE
- OpenTofu
- Ansible
- cloud-init

## Kubernetes

- Talos Linux
- Kubernetes
- Cilium

## GitOps

- Argo CD
- Helm
- Kustomize

## Networking

- OpenWrt
- VLANs
- firewall rules
- Gateway API
- Traefik where appropriate
- Cloudflare Tunnel for externally exposed services

## TLS

- cert-manager
- Let's Encrypt where appropriate

## Secrets

- SOPS
- age
- OpenBao
- External Secrets Operator if appropriate

Use SOPS/age for encrypted bootstrap/configuration secrets stored in Git.

Use OpenBao for runtime secrets where appropriate.

Never commit plaintext secrets.

## Identity

- Authentik
- OIDC
- MFA
- RBAC

## CI/CD

- GitHub Actions
- GitHub Container Registry

CI and CD must remain logically separated:

GitHub Actions = CI/build/test/security

Argo CD = Kubernetes CD/GitOps reconciliation

## Observability

- Prometheus
- Grafana
- Loki
- Grafana Alloy
- Alertmanager

## Databases

- PostgreSQL
- CloudNativePG for Kubernetes-managed PostgreSQL

## Backup

- Proxmox Backup Server when appropriate
- Restic/Kopia for application/data backups
- encrypted off-site backup

Follow the 3-2-1 backup principle.

## Security

- Trivy
- Gitleaks
- Checkov
- Semgrep
- Kubernetes NetworkPolicies
- RBAC
- least privilege

## Automation

- Renovate
- pre-commit
- just
- yamllint
- shellcheck
- shfmt
- kubeconform

---

# 4. Repository architecture

Create and maintain a repository

Adapt the professional repository best practices, but preserve clear separation between infrastructure, platform, and applications.

---

# 5. Suggested Network architecture

Research and suggest with documented technical reasons to change or replace Network architecture with something better and superior and professional:

Design the network around VLAN segmentation.

Initial logical VLANs should be:

VLAN 10 - Management

VLAN 20 - Trusted LAN

VLAN 40 - DMZ/Public Services

VLAN 50 - Servers/Kubernetes

VLAN 60 - IoT

VLAN 70 - Guest

Do not assume every VLAN must be implemented immediately.

Create a documented network policy matrix.

Default policy:

DENY unless explicitly allowed.

Examples:

IoT -> Internet: allowed where required

IoT -> Trusted LAN: denied

Guest -> Trusted LAN: denied

Guest -> Servers: denied

DMZ -> Management: denied

DMZ -> Trusted LAN: denied

Kubernetes -> Management: denied unless explicitly required

Management -> infrastructure: allowed

Document every exception.

---

# 6. Suggested Infrastructure provisioning

Research and suggest with documented technical reasons to change or replace current Infrastructure provisioning with something better and superior and professional:

Do not manually create VMs unless required for initial bootstrap.

Use:

OpenTofu
→ Proxmox VM
→ cloud-init
→ Ansible/Talos

OpenTofu should manage:

- VM resources
- CPU
- memory
- disks
- network interfaces
- VLAN configuration
- VM tags
- cloud-init
- IP configuration where practical

Use modules where useful.

Use remote state if an appropriate backend is available.

Never commit sensitive state files.

---

# 7. Suggested OS configuration

Research and suggest with documented technical reasons to change or replace current OS configuration with something better and superior and professional:


Ansible manage:

- users
- SSH
- SSH hardening
- sudo
- packages
- NTP
- timezone
- firewall
- automatic security updates
- monitoring
- backup agents
- system configuration

Avoid shell scripts for tasks that Ansible can model declaratively.

Make Ansible playbooks idempotent.

---

# 8. Kubernetes

Use Talos Linux for Kubernetes nodes.

Do not SSH into Talos nodes for normal administration.

Use Talos APIs and declarative configuration.

Create a Kubernetes cluster suitable for the available hardware.

Because there is only one physical Proxmox host, do not falsely advertise physical HA.

Use multiple VMs only when the resource budget permits.

Document resource allocation.

---

# 9. Cilium

Use Cilium as the Kubernetes CNI.

Enable Kubernetes NetworkPolicies.

Use least-privilege network access.

Do not allow every namespace to communicate freely.

Create policies for:

- infrastructure
- monitoring
- databases
- applications
- ingress
- external access

Use Hubble if resource consumption is acceptable.

---

# 10. GitOps

Argo CD is the Kubernetes deployment authority.

Normal application deployment workflow:

Developer
→ Git commit
→ GitHub
→ CI
→ image build
→ security scan
→ GHCR
→ GitOps configuration update
→ Argo CD
→ Kubernetes

Do not normally use:

kubectl apply

for persistent application deployment.

kubectl is primarily for diagnostics and emergency operations.

Argo CD should reconcile desired state from Git.

Do not configure Argo CD to manage arbitrary local manifests.

---

# 11. Helm and Kustomize

Use Helm for third-party applications.

Use Kustomize overlays when environment-specific configuration is needed.

Avoid copying huge upstream Helm charts into the repository.

Pin versions.

Never use unpinned "latest" images in production-style manifests.

---

# 12. Secrets

This is a critical requirement.

Never commit:

- passwords
- API keys
- tokens
- private keys
- plaintext .env files
- kubeconfig credentials
- cloud credentials
- OpenTofu sensitive variables

Use:

SOPS + age

for encrypted Git secrets.

Use OpenBao for runtime secret management.

Use External Secrets Operator where appropriate to inject secrets into Kubernetes.

Secrets must have clear ownership and rotation procedures.

Document bootstrap/recovery procedures for the secrets system.

---

# 13. Identity

Deploy Authentik.

Use OIDC wherever supported.

Avoid separate local passwords for every application.

Use:

- MFA
- groups
- RBAC
- least privilege

Create separate administrative and normal user roles where practical.

Do not use shared administrator accounts.

---

# 14. CI

GitHub Actions must validate pull requests.

At minimum run:

- YAML validation
- Helm lint
- Kustomize build
- OpenTofu fmt
- OpenTofu validate
- Ansible lint
- shellcheck
- shfmt
- kubeconform
- Gitleaks
- Trivy
- Checkov
- Semgrep where appropriate

Fail CI on serious security problems.

Do not expose secrets to untrusted pull requests.

---

# 15. Container images

Build application images using GitHub Actions.

Push to:

GitHub Container Registry

Never deploy arbitrary mutable tags.

Prefer immutable version tags or image digests.

Use Trivy to scan images.

Configure Renovate to track image updates.

---

# 16. Observability

Deploy:

Prometheus
Grafana
Loki
Grafana Alloy
Alertmanager

Monitor:

- Proxmox
- VMs
- Kubernetes nodes
- Kubernetes control plane
- pods
- containers
- storage
- CPU
- memory
- network
- certificates
- backups
- important applications

Create useful dashboards rather than installing dashboards without understanding them.

---

# 17. Alerting

Create actionable alerts.

Examples:

- node unavailable
- disk nearly full
- filesystem errors
- memory exhaustion
- CPU saturation
- pod CrashLoopBackOff
- deployment unavailable
- certificate nearing expiration
- backup failure
- Kubernetes control-plane problems
- database problems

Avoid noisy alerts.

Every alert should have a documented response/runbook.

---

# 18. Backup

Implement backup according to:

3 copies
2 media types
1 off-site copy

Separate:

- VM backups
- Kubernetes application backups
- database backups
- configuration backups
- secrets recovery

Test restoration.

A backup that has never been restored is not considered verified.

Create:

docs/runbooks/restore-*.md

for critical recovery procedures.

---

# 19. Disaster recovery

Create a complete disaster recovery procedure.

The documentation must answer:

"If the Proxmox server is completely destroyed, how do I rebuild the environment?"

The ideal process should be:

New hardware
→ Proxmox
→ OpenTofu
→ VMs
→ Talos
→ Kubernetes
→ Argo CD
→ infrastructure controllers
→ secrets
→ applications
→ data restore

Identify every step that still requires manual intervention.

The long-term goal is to minimize those manual steps.

---

# 20. Security model

Apply:

- least privilege
- default deny networking
- RBAC
- MFA
- SSH key authentication
- no password SSH
- no root SSH where avoidable
- minimal container privileges
- read-only filesystems where practical
- non-root containers where practical
- resource limits
- NetworkPolicies
- encrypted secrets
- encrypted backups
- regular patching
- vulnerability scanning
- secret scanning
- audit logs

Do not disable security controls merely to make installation easier.

If a temporary bootstrap exception is required, document it and create a task to remove it.

---

# 21. Documentation

Every infrastructure component must have documentation explaining:

- purpose
- architecture
- dependencies
- deployment
- configuration
- security considerations
- backup
- restore
- troubleshooting
- removal

Maintain:

README.md
ARCHITECTURE.md
SECURITY.md
DISASTER-RECOVERY.md

and operational runbooks.

Do not allow undocumented architectural decisions.

Record important decisions as ADRs where appropriate.

---

# 22. Change management

Treat infrastructure changes like production changes.

Use:

branch
→ pull request
→ CI
→ review
→ merge
→ deployment
→ validation

Do not make unexplained manual production changes.

If an emergency manual change is necessary:

1. perform the change
2. document it
3. reproduce it in Git
4. remove the configuration drift

---

# 23. Resource constraints

The primary host only has 16 GB RAM.

Do not deploy unnecessary services.

Before deploying a new platform component:

1. determine its resource requirements
2. determine whether it overlaps with an existing component
3. determine whether it materially improves the platform
4. determine whether it can be postponed
5. document the decision


---

# 24. Implementation methodology

Do NOT attempt to deploy the entire platform in one step.

Work in phases.

suggested Phases

Phase 0:
Inventory existing hardware and network.

Phase 1:
Repository and engineering standards.

Phase 2:
Proxmox + OpenTofu.

Phase 3:
Ansible baseline and host security.

Phase 4:
Talos + Kubernetes.

Phase 5:
Cilium.

Phase 6:
Argo CD.

Phase 7:
cert-manager + Gateway/API ingress.

Phase 8:
SOPS + age.

Phase 9:
OpenBao + External Secrets.

Phase 10:
Authentik.

Phase 11:
Prometheus + Grafana + Loki + Alloy + Alertmanager.

Phase 12:
Backup.

Phase 13:
Security scanning.

Phase 14:
Renovate.

Phase 15:
Applications.

Phase 16:
Disaster recovery testing.

Do not move to the next phase until the previous phase has been validated.

---

# 25. Agent operating rules

You are an autonomous infrastructure engineer, but infrastructure is safety-critical.

Before making destructive changes:

- inspect
- explain
- verify
- backup
- then change

Never:

- delete VMs without approval
- destroy storage
- overwrite existing configuration blindly
- expose management services publicly
- commit secrets
- disable firewalls without justification
- expose Kubernetes API publicly
- expose Proxmox publicly
- expose OpenBao publicly
- expose SSH publicly unless explicitly required

Prefer:

- pull requests
- small changes
- reversible changes
- idempotent automation
- version pinning
- documented assumptions

---

# 26. Decision-making rules

When you encounter ambiguity:

1. inspect existing files/configuration
2. inspect the current infrastructure
3. determine dependencies
4. choose the simplest production-grade solution
5. document the decision
6. implement incrementally

Do not invent infrastructure.

Do not assume an IP address, VLAN ID, domain, storage device, credential, or hardware capability without verifying it.

If information is missing and the decision could cause data loss or network disruption, stop and ask for confirmation.

For non-destructive decisions, make a reasonable assumption and document it.

---

# 27. Definition of done

A component is not considered complete merely because it works.

It is complete only when:

- configuration is in Git
- deployment is automated
- secrets are protected
- CI validates the configuration
- monitoring exists
- backup exists where applicable
- documentation exists
- recovery procedure exists where applicable
- security implications are considered
- versions are pinned
- configuration drift is minimized
- deployment is reproducible

---

# 28. First task

Do NOT start installing anything yet.

First perform an infrastructure discovery and architecture assessment.

Inspect the repository.

Create:

docs/INITIAL-ASSESSMENT.md

containing:

1. Hardware inventory
2. Current Proxmox configuration
3. Current OpenWrt/network configuration if available
4. Existing VLANs
5. Existing IP ranges
6. Existing storage
7. Existing services
8. Existing Docker infrastructure
9. Existing Cloudflare configuration
10. Existing Git repositories
11. Existing secrets/configuration risks
12. Resource constraints
13. Proposed target architecture
14. Migration risks
15. Recommended implementation phases

Also create:

docs/ARCHITECTURE.md

with the proposed architecture.

Create an ADR explaining the major technology choices:

docs/adr/0001-platform-stack.md

Do not destroy, reinstall, or migrate anything during this first phase.

Only inspect and document.

After completing the assessment, present:

- current state
- target state
- architecture diagram
- proposed repository structure
- resource allocation
- network design
- security model
- implementation phases
- risks
- assumptions
- questions requiring human approval

Then wait for approval before performing destructive or migration operations.

Everything above is a suggestion and I would like you to improve upon it and propose a better and superior and professional architecture. 