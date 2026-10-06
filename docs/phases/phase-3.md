# Phase 3 gate record: hypervisor

Status: **in progress.** Steps 3.1 to 3.4 of `phase-3-plan.md` are done, including the bridges and the exporters; 3.5 to 3.7 are open. Dates are 2026-10-06 unless stated.

## What was done

| Step | Result |
|---|---|
| 3.1 Install media | Built on Node 1 itself from the answer file in Git and the private inventory, embedded in the official 9.2 image (checksum verified), written to the stick and read back for comparison. The first attempt failed twice: the host's RAM disk was too small for the image, and the stick, an SD card in a USB reader on an extension cable, reset under load. On a rear port the same reader passed a 256 MiB write and read test and the install media verified |
| 3.2 Reinstall | One-time boot into the installer, no hands on the machine. The new system came back on 10.0.10.10 after about five minutes as `pve1`, booting UEFI, with the planned layout: 20 GiB root, 4 GiB swap, 190.7 GiB thin pool. Both SSH keys authorised for root by the installer. The installer boot entry was removed afterwards |
| 3.3 Measurements | Below |
| 3.4 Ansible | Bootstrap play: operator account with both keys, root login over SSH closed, root keeps the recovery key only. Host play, idempotent on the second run: free Proxmox repository, Intel microcode, SSH key-only on the management address for the operator only, chrony with the router as the only source and serving the servers network, swap as a safety net, KSM off, persistent capped journal, host firewall with policy DROP and the exceptions below |
| 3.4 Bridges and metrics (second pull request) | `vmbr0` made VLAN-aware with the servers VLAN tagged for guests, `vmbr1` created on the 2.5 GbE port with the point-to-point address, IP forwarding off. Applied through the guarded path: parse first, revert timer armed, reload detached, confirmed only after the host answered with the expected VLANs and bridges; the SSH session did not even drop. `node_exporter` 1.12.1 and `smartctl_exporter` 0.14.0 from the `prometheus.prometheus` collection on the management address, a timer feeding thin-pool usage to the textfile collector. The play is idempotent (`changed=0` on the following run) |
| 3.4 Access (third pull request) | Custom roles `TerraformProvisioner` and `KubernetesCSI` from the design's privilege lists (every name exists on 9.2), pool `talos`, the owner's `octenite-admin@pve` as the only Administrator (password generated into the private inventory), four automation users with scoped entries, and four privilege-separated tokens with a 12-month expiry whose secrets went straight into `private/proxmox/tokens.sops.yaml` without being displayed. Token scope proven from the workstation: see below |

## Measurements

| Item | Value | Effect on the design |
|---|---|---|
| Memory visible to Linux | 15918 MiB (15.54 GiB) | As assumed |
| Idle memory used, host alone, after configuration | 1.55 to 1.9 GiB over several readings | Above the 1.5 GiB gate; the worker VM is created at 8.5 GiB, as the design foresaw |
| Onboard port | 1000 Mbit/s, `r8169`, now named `enp3s0` | Fine |
| 2.5 GbE port | No link, now named `enp2s0` | Step 3.7 |
| Microcode | Revision 0x21, loaded early from 0x19; one vulnerability (SRBDS) remains without a fix | Exception X13 stands |
| Thin pool, synchronous writes (8 KiB sequential, fdatasync on every write, 30 s) | about 1480 writes per second; fsync latency p99 2.2 ms, p99.9 33 ms; write latency p99 5 ms | Passes the 25 ms gate for etcd; the SSD stays |
| Time | Synchronised to the router, stratum 3 to 4; the host serves time with a local fallback at stratum 10 | As designed (E13) |

## Host firewall tests

The probe from OpenWrt devices uses their SSH client against each port: a timeout means the packet was dropped, a refusal means it reached the host, anything else means the port answered. Controls on the router itself: its own SSH port reads as open, a closed port reads as refused.

| From | Port | Expected | Result |
|---|---|---|---|
| Workstation | SSH, web interface | allow | pass |
| Router (management network) | SSH, web interface, console ports, migration, exporter | drop | pass |
| Router | ping | allow | pass |
| Access point 1 (management network) | web interface | drop | pass |
| Access point 1 | SSH | drop | dropped ("Operation timed out"), repeated 2026-10-06 once the wired link was back |
| Access point 1 | ping | drop | pass |
| Workstation | exporters (9100, 9633) | drop | pass: the connection fails from the pinned address, which is not in E7 |
| Workstation | SSH after the bridge change | allow | pass |

During the first probe the workstation's dock adapter disappeared and its traffic moved to Wi-Fi with another address, which every firewall rejected. That confirmed exception E2 from the wrong side: nothing in the lab answers a workstation that is not on its pinned address. The owner then asked to work from Wi-Fi as well and chose, from three options, to bind the pinned address to the laptop's Wi-Fi adapter too (MAC randomisation is off for the trusted network); the two adapters are never up at the same time, which is the case dnsmasq documents for a host entry with several hardware addresses. No firewall rule changed anywhere. The alternative, a key-bound WireGuard tunnel on the router, is recorded in the backlog for when remote access is designed. Verified the same day with the dock unplugged: the Wi-Fi adapter holds the pinned address, SSH to the router, an access point and the hypervisor works, the exporter port stays closed. One-time step: a client that already holds another lease keeps it on reconnect (the server only applies the reservation to a fresh request), so the lease was released and renewed once from an elevated prompt.

## Token scope tests

Run from the workstation against the API with the stored tokens; the expected answer is 200 for a call inside the scope and 403 outside it.

| Token | Inside scope | Outside scope |
|---|---|---|
| `drift@pve!weekly` (auditor) | version, user list: 200 | create a pool: 403 |
| `prometheus@pve!exporter` (auditor) | node status: 200 | - |
| `terraform@pve!tofu` | pool `talos`, storage list, next VM id: 200 (the pool answered 403 until `Pool.Audit` was added) | - |
| `kubernetes-csi@pve!csi` | storage content: 200 | node status: 403 |
| no token | - | version: 401 |

## Defects found and fixed

| Defect | Fix |
|---|---|
| Proxmox has no `sudo`, and its subscription repository blocks `apt update` | The bootstrap play fixes the repositories and installs sudo before anything else |
| The cluster filesystem under `/etc/pve` refuses permission changes and atomic replacement, which Ansible's copy needs | Firewall files are compared with their wanted content and, only when they differ, written in place |
| The cluster-wide firewall file rejects `log_level_in` | Removed from that file |
| pve-firewall adds built-in rules that admit the host's own subnet to SSH, the web interface, the console ports and migration, and that subnet cannot be removed from its "management" set | Host rules run first, so an explicit drop for the rest of the management network on those ports follows the workstation's accept rules (X10) |
| A failure late in the play left services on their old configuration (chrony, sshd) | Pending restarts are applied before the play ends |
| The media builder required the stick's serial even for the reboot command, so the first reboot never happened | Fixed |
| ifupdown2 3.3 fails its syntax check on `bridge-fd 0`, which the installer itself writes; the installed file fails the same check | The managed file carries no forward delay (meaningless with STP off); the parse gate stays strict |
| The upstream `smartctl_exporter` unit runs as an unprivileged user without access to the disk, so it exported no SMART data | A systemd drop-in grants the disk group and the raw-command capability, nothing else |
| The textfile directory was fought over by two roles (owner and mode), so the play was never clean | The host role creates it with the mode the exporter role wants and leaves ownership to that role |

## Open

| # | Item | Who |
|---|---|---|
| 1 | Backup server VM on the workstation, first host backup, restore test | Owner (elevated PowerShell) and operator |
| 2 | OpenTofu state backend | Owner creates the storage account; operator |
| 3 | 2.5 GbE link: `enp2s0` still reports no carrier on the new install | Operator, with the owner at the cable |
| 4 | Copy the `root@pam` and `octenite-admin@pve` passwords to the password manager (`just reveal private/proxmox/pve1.sops.yaml pve_root_password`, `just reveal private/ansible/inventory/host_vars/pve1/secrets.sops.yaml pve_admin_password`) | Owner |
| 5 | Enrol TOTP for `octenite-admin@pve` and for `root@pam` in the web interface (Datacenter, Permissions, Two Factor); then the operator sets the realm to require it | Owner, then operator |
| 6 | CSI entries on the worker VMs, once their IDs exist | Operator, Phase 7 |
