# Phase 3 gate record: hypervisor

Status: **in progress.** Steps 3.1 to 3.4 of `phase-3-plan.md` are done; 3.5 to 3.7 are open. Dates are 2026-10-06 unless stated.

## What was done

| Step | Result |
|---|---|
| 3.1 Install media | Built on Node 1 itself from the answer file in Git and the private inventory, embedded in the official 9.2 image (checksum verified), written to the stick and read back for comparison. The first attempt failed twice: the host's RAM disk was too small for the image, and the stick, an SD card in a USB reader on an extension cable, reset under load. On a rear port the same reader passed a 256 MiB write and read test and the install media verified |
| 3.2 Reinstall | One-time boot into the installer, no hands on the machine. The new system came back on 10.0.10.10 after about five minutes as `pve1`, booting UEFI, with the planned layout: 20 GiB root, 4 GiB swap, 190.7 GiB thin pool. Both SSH keys authorised for root by the installer. The installer boot entry was removed afterwards |
| 3.3 Measurements | Below |
| 3.4 Ansible | Bootstrap play: operator account with both keys, root login over SSH closed, root keeps the recovery key only. Host play, idempotent on the second run: free Proxmox repository, Intel microcode, SSH key-only on the management address for the operator only, chrony with the router as the only source and serving the servers network, swap as a safety net, KSM off, persistent capped journal, host firewall with policy DROP and the exceptions below |

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
| Access point 1 | SSH | drop | not completed: the workstation lost its wired link during the probe (see below); the router row covers the same rule |
| Access point 1 | ping | drop | pass |

During the last probe the workstation's dock adapter disappeared and its traffic moved to Wi-Fi with another address, which every firewall rejects by design. That confirmed exception E2 from the wrong side: nothing in the lab answers a workstation that is not on its pinned address. The remaining probe is repeated when the wired link is back.

## Defects found and fixed

| Defect | Fix |
|---|---|
| Proxmox has no `sudo`, and its subscription repository blocks `apt update` | The bootstrap play fixes the repositories and installs sudo before anything else |
| The cluster filesystem under `/etc/pve` refuses permission changes and atomic replacement, which Ansible's copy needs | Firewall files are compared with their wanted content and, only when they differ, written in place |
| The cluster-wide firewall file rejects `log_level_in` | Removed from that file |
| pve-firewall adds built-in rules that admit the host's own subnet to SSH, the web interface, the console ports and migration, and that subnet cannot be removed from its "management" set | Host rules run first, so an explicit drop for the rest of the management network on those ports follows the workstation's accept rules (X10) |
| A failure late in the play left services on their old configuration (chrony, sshd) | Pending restarts are applied before the play ends |
| The media builder required the stick's serial even for the reboot command, so the first reboot never happened | Fixed |

## Open

| # | Item | Who |
|---|---|---|
| 1 | Access-point rows of the firewall table | Operator, when the probe finishes |
| 2 | `vmbr0` VLAN-aware with the servers VLAN, `vmbr1` on the 2.5 GbE port, both with a guarded reload | Operator |
| 3 | Node and SMART exporters on the management address (E7) | Operator |
| 4 | Users and API tokens for OpenTofu, the storage driver and the exporter, with the secrets captured into the private repository | Operator, attended |
| 5 | Backup server VM on the workstation, first host backup, restore test | Owner (elevated PowerShell) and operator |
| 6 | OpenTofu state backend | Owner creates the storage account; operator |
| 7 | 2.5 GbE link | Operator, from the new install |
| 8 | Copy the root password to the password manager | Owner |
