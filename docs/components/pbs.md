# Component: Proxmox Backup Server (VM on the workstation)

## Purpose

The local backup target: nightly images of the control-plane VM and the hypervisor's configuration, deduplicated and verified. It runs as a Hyper-V VM on Node 2, the Windows workstation, because Node 1 has no memory to spare and a backup server should not live on the host it protects. It is the second copy of the 3-2-1 rule; the off-site copy is a separate component.

## Architecture

- `pbs1`, Hyper-V Generation 1 (BIOS), 2 vCPU, 4 GiB fixed; 32 GiB system disk on IDE and a 128 GiB fixed datastore disk on SCSI, both under `F:\homelab\pbs1\disks`. Checkpoints disabled. Started by hand (owner decision 2026-10-06); a clean shutdown follows the host. Generation 2 was tried first and abandoned: the Proxmox installer's early environment lacks the synthetic Hyper-V storage and keyboard drivers, so it saw neither its DVD nor the console keyboard; the emulated devices of a Generation 1 VM work, and the installed system uses the synthetic drivers. Secure Boot is therefore unavailable (X7).
- Two network legs:
  - `nat` (switch `pbs-nat`, 10.0.98.3/29, gateway the workstation at 10.0.98.1): updates, notifications, and the fallback path. A Hyper-V port ACL denies every private address except the workstation, so the VM can never reach the lab or the router through the workstation's NAT.
  - `p2p` (switch `p2p` on the USB 2.5 GbE adapter, 10.0.99.3/29): the primary path from the hypervisor, present only while the adapter is plugged in. Port ACL: the hypervisor's address only.
- Fallback path (E14): the workstation forwards port 8007 on its pinned address to the VM's NAT leg, the Windows firewall admits only the hypervisor, and the router allows hypervisor to workstation on 8007. The hypervisor switches its backup target between the two addresses by itself.
- Resource budget on the workstation: Windows about 6 GiB, WSL capped at 5 GB, PBS 4 GiB fixed.

## Dependencies

- The workstation being on; nothing in the lab depends on the backup server.
- The hypervisor builds the install image (it has the assistant and the bandwidth).

## Deployment

| Step | How |
|---|---|
| VM, switches, NAT, ACLs, firewall, port forward, WSL cap | elevated PowerShell: `scripts\node2\pbs-vm.ps1`; idempotent, prints only changes |
| Install image | `scripts/pbs/build-install-iso.sh` from WSL with a session open; answer file `infrastructure/pbs/answer.toml.tmpl`, root password in the private repository `proxmox/pbs1.sops.yaml` |
| First boot | `pbs-vm.ps1 -Iso F:\homelab\iso\pbs1-auto.iso` with the VM off: the datastore disk is detached, the installer runs unattended on the only disk and reboots into the system; then `pbs-vm.ps1 -Eject`, which detaches the medium and attaches the datastore disk |
| Configuration | Ansible, `playbooks/pbs.yaml` (datastore, users and token, firewall, schedules) |

## Configuration

| What | Where |
|---|---|
| Sizes, addresses, MAC addresses, ACLs | `scripts/node2/pbs-vm.ps1` (settings block) |
| Install layout, address, keys | `infrastructure/pbs/answer.toml.tmpl` |
| Root password | private repository, `proxmox/pbs1.sops.yaml` |
| Host policy | `infrastructure/ansible/roles/pbs_host/` |

## Security considerations

- The VM lives on an unencrypted disk of a personal laptop (X23, X7): backups are client-side encrypted on the hypervisor; the key never lives on the workstation.
- Both legs are fenced: port ACLs on the VM, the Windows firewall on the host, nftables in the guest. The VM's NAT traffic leaves with the workstation's address, which the router trusts (E1 to E3); the ACL that denies private destinations is what keeps that trust from leaking to the VM.
- Nothing inbound on the direct link reaches the workstation.

## Backup

The datastore is the backup. Its content is reproducible from the sources plus the off-site copy; the VM itself is rebuilt from Git.

## Restore

See `docs/runbooks/restore-pbs.md` (added with the first restore test).

## Troubleshooting

| Symptom | Check |
|---|---|
| Hypervisor cannot reach the backup server | `Get-VM pbs1` state; direct link: `ping 10.0.99.3` from the hypervisor; fallback: `netsh interface portproxy show v4tov4` and the firewall rule `homelab-pbs1-8007` on the workstation |
| The installer stops with "no device with valid ISO found" or the console cannot send keys | The VM is Generation 2; rebuild it with `pbs-vm.ps1 -Recreate` (Generation 1) |
| The system landed on the 128 GiB disk | Both disks were attached during the install and their names swapped. Stop the VM, `pbs-vm.ps1 -WipeDatastore -Iso ...` (deletes and recreates the datastore disk file, installs on the only attached disk), then `-Eject` |
| The VM boots into an initramfs shell complaining about `pbs-OLD-…` | The system disk carried an older install whose GRUB still boots. Stop the VM, `pbs-vm.ps1 -WipeSystem -Iso ...`, then `-Eject` |
| The host play refuses the datastore disk | It holds something other than the datastore partition; read the `lsblk` output in the message before deciding whether `-WipeDatastore` is right |
| The VM has no internet | The NAT: `Get-NetNat pbs-nat`; the ACLs: `Get-VMNetworkAdapterAcl -VMName pbs1` |

## Removal

`Remove-VM pbs1`, delete `F:\homelab\pbs1`, `Remove-NetNat pbs-nat`, `Remove-VMSwitch pbs-nat`, `Remove-VMSwitch p2p`, the two firewall rules and the port forward; the router rule E14 goes with the template.
