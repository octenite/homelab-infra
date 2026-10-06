# Component: Proxmox VE host

## Purpose

Node 1 runs Proxmox VE and hosts the Talos VMs. It is the single physical host of the platform. Nothing about it is highly available; its recovery is a reinstall from Git plus a restore.

## Architecture

- One host, `pve1`, in the management network at 10.0.10.10, on the onboard gigabit port.
- Storage: ext4 root, swap as a safety net, and an LVM thin pool for VM disks and, later, Kubernetes volumes.
- Firewall: pve-firewall with policy DROP and the exceptions E2, E6, E7 and E13 from [ARCHITECTURE.md](../ARCHITECTURE.md) section 6.
- Time: the router is the only source; the host serves the servers network with a local fallback.

## Dependencies

- The router: address, default route, DNS and time.
- Nothing inside the lab.

## Deployment

The host is installed unattended and configured by Ansible. Nothing is configured by hand.

| Step | How |
|---|---|
| Install | `scripts/pve/build-install-media.sh prepare`, then `reboot`. The answer file is `infrastructure/proxmox/answer.toml.tmpl`; the secrets and identifiers it needs are in the private repository under `proxmox/` |
| First contact | `ansible-playbook playbooks/pve-bootstrap.yaml`, as root with the key the installer authorised |
| Configuration | `ansible-playbook playbooks/pve.yaml`, as the operator account; idempotent |

Both plays run from the workstation with a session open.

## Configuration

| What | Where |
|---|---|
| Install layout, address, keys | `infrastructure/proxmox/answer.toml.tmpl` |
| Host policy: repositories, SSH, time, memory, logs, firewall | `infrastructure/ansible/roles/pve_host/` |
| Addresses the rules refer to | `infrastructure/ansible/playbooks/group_vars/proxmox.yaml` |
| Root password, disk and stick serial numbers, notification address | private repository, `proxmox/` |

Quirks worth knowing: `/etc/pve` is a cluster filesystem that refuses permission changes and atomic replacement, so the role compares and writes firewall files in place. pve-firewall always admits the host's own subnet to its management ports through a built-in set; the role drops the rest of that subnet explicitly.

## Security considerations

- SSH is key-only, for the operator account only, on the management address only. Root keeps the recovery key for the console-equivalent path.
- `root@pam` with its password is break-glass for the console and the web interface. The password lives in the private repository and the password manager.
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

## Removal

Not applicable: it is the only host.
