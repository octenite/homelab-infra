# Component: Proxmox VE host

## Purpose

Node 1 runs Proxmox VE and hosts the Talos VMs. It is the single physical host of the platform. Nothing about it is highly available; its recovery is a reinstall from Git plus a restore.

## Architecture

- One host, `pve1`, in the management network at 10.0.10.10, on the onboard gigabit port.
- Bridges: `vmbr0` on the onboard port, VLAN-aware, host address untagged and the servers VLAN tagged for guests; `vmbr1` on the 2.5 GbE port with 10.0.99.1/29, the direct link to the workstation for backups, no guests. The host does not route between them.
- Storage: ext4 root, swap as a safety net, and an LVM thin pool for VM disks and, later, Kubernetes volumes.
- Firewall: pve-firewall with policy DROP and the exceptions E2, E6, E7 and E13 from [ARCHITECTURE.md](../ARCHITECTURE.md) section 6.
- Time: the router is the only source; the host serves the servers network with a local fallback.
- Metrics: `node_exporter` (9100) and `smartctl_exporter` (9633) from the upstream Ansible collection, bound to the management address; a timer adds thin-pool usage through the textfile collector. Only the Talos workers may scrape them (E7).

## Dependencies

- The router: address, default route, DNS and time.
- Nothing inside the lab.

## Deployment

The host is installed unattended and configured by Ansible. Nothing is configured by hand.

| Step | How |
|---|---|
| Install | `scripts/pve/build-install-media.sh prepare`, then `reboot`. The answer file is `infrastructure/proxmox/answer.toml.tmpl`; the secrets and identifiers it needs are in the private repository under `proxmox/` |
| First contact | `ansible-playbook playbooks/pve-bootstrap.yaml`, as root with the key the installer authorised |
| Configuration | `just pve-apply` (`playbooks/pve.yaml`), as the operator account; idempotent |
| API tokens | `just pve-tokens` (`playbooks/pve-tokens.yaml`), attended; issues what is missing and stores the secrets in the private repository |

Both plays run from the workstation with a session open.

## Configuration

| What | Where |
|---|---|
| Install layout, address, keys | `infrastructure/proxmox/answer.toml.tmpl` |
| Host policy: repositories, SSH, time, memory, logs, bridges, firewall, thin-pool metrics | `infrastructure/ansible/roles/pve_host/` |
| Roles, users, pool, ACLs, token list | `infrastructure/ansible/playbooks/group_vars/proxmox.yaml` |
| Exporter versions and listen addresses | `infrastructure/ansible/playbooks/group_vars/proxmox.yaml`; the roles come from the `prometheus.prometheus` collection pinned in `requirements.yml` |
| Addresses the rules refer to | `infrastructure/ansible/playbooks/group_vars/proxmox.yaml` |
| Root password, disk and stick serial numbers, notification address | private repository, `proxmox/` |

Quirks worth knowing: `/etc/pve` is a cluster filesystem that refuses permission changes and atomic replacement, so the role compares and writes firewall files in place. pve-firewall always admits the host's own subnets to its management ports through a built-in set; the role drops the rest of those subnets explicitly.

A change to the bridges is guarded: the role parses the new interfaces file first, arms a transient systemd timer that restores the previous file, applies the change detached from the SSH session with `ifreload`, and disarms the timer only after the host answers again on its management address with the expected VLANs and bridges. A change that is not confirmed within three minutes is undone by the host itself.

## Security considerations

- SSH is key-only, for the operator account only, on the management address only. Root keeps the recovery key for the console-equivalent path.
- `root@pam` with its password is break-glass for the console and the web interface. The password lives in the private repository and the password manager.
- The owner's `octenite-admin@pve` is the only account holding `Administrator`; its password is in the private inventory and the owner enrols TOTP in the web interface. Both realms require a second factor; the role switches that on only once every password user of a realm has enrolled, so a rebuilt host first lets the owner enrol. Recovery keys (Two Factor → Add → Recovery Keys) are the owner's fallback for a lost phone. Automation uses privilege-separated API tokens of dedicated users with custom roles (`TerraformProvisioner`, `KubernetesCSI`) or `PVEAuditor`, scoped to the `talos` pool, the two storages, the node and the bridge where the API accepts a path. Tokens live 12 months; their secrets are issued by `just pve-tokens` straight into `private/proxmox/tokens.sops.yaml`. Rotation: remove the token on the host, run `just pve-tokens`, update the consumer.
- Only the workstation reaches SSH, the web interface and the console ports. Future Talos workers reach the API and the exporters.
- The CPU receives no microcode updates any more; one vulnerability stays open (X13).

## Backup

The host configuration is reproducible from Git. A backup of `/etc` and `/etc/pve` to the backup server is added in Phase 3.5.

## Restore

Reinstall from the answer file, then run the two plays. Tokens are re-issued. See [DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| The web interface is unreachable from the workstation | The workstation must hold 192.168.1.196; `pve-firewall status` on the host |
| A device in the management network reaches a host port | It must not: the host rules drop the subnet on the management ports; `iptables -S PVEFW-HOST-IN` |
| Time wrong | `chronyc sources`; the router is the only source |
| The play fails on `/etc/pve` | Permission or replace errors: the file must be written in place, not copied |
| The play failed in the bridge change | Wait three minutes; the host restores its previous file (`journalctl -t homelab`). Then `ifquery --check -a` and run the play again |
| The second factor is lost and no recovery key exists | Over SSH with the recovery key as root: `pveum user tfa list <user>`, `pveum user tfa delete <user> --id <entry>`; log in with the password, enrol again. The realm requirement stays on |
| The 2.5 GbE link is down | `ethtool enp2s0` for link and speed; the bridge `vmbr1` stays up without a link, nothing else depends on it |

## Removal

Not applicable: it is the only host.
