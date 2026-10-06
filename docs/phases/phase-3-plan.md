# Phase 3 plan: hypervisor

Status: **approved by the owner on 2026-10-06 ("GO, all access granted"); in progress.** The design is `docs/ARCHITECTURE.md` sections 3 and 4; the measured facts are in `docs/INITIAL-ASSESSMENT.md`.

Goal: Node 1 reinstalled from an answer file in Git, hardened by Ansible, with its host backup, exporters and notifications in place, and the backup server VM on the workstation. The owner asked that the 2.5 GbE direct link not block anything: it is troubleshot from the new install, and the backup path falls back to the workstation's onboard port if needed.

## What the owner will notice

Nothing on the household network. Node 1 is unreachable for about ten minutes during the reinstall. It holds no guests and no data.

## Steps

| # | Step | Gate |
|---|---|---|
| 3.1 | Install media built on Node 1 itself: answer file rendered from Git plus the private inventory, embedded into the official 9.2 ISO (checksum verified), written to the USB stick in Node 1, one-time boot set | `validate-answer` passes; the ISO checksum matches the published value; the stick is identified by serial number before it is written |
| 3.2 | Reboot into the installer. It wipes the disk, installs with ext4 and the planned LVM layout, sets the final address and the two SSH keys, and reboots into the new system | Node 1 answers at 10.0.10.10 with a new host key; root logs in with the lab key only; the disk layout matches the plan |
| 3.3 | Measurements that re-base the design: memory visible to Linux and idle use, NIC link speeds, microcode and vulnerability files, synchronous-write benchmark of the thin pool | Recorded in `docs/phases/phase-3.md`; the worker VM size is decided from them |
| 3.4 | Ansible: bootstrap play (sudo user, key-only SSH, root login off), then the host play (firewall, chrony as second time source, unattended security updates, microcode, journald, KSM off, exporters, notifications, backup client timer, API users and tokens) | Each play idempotent on a second run; firewall deny tests from the servers and trusted networks; host without guests at or under 1.5 GiB |
| 3.5 | Backup server VM on the workstation (Hyper-V), the direct-link or fallback path, first host backup and a restore of it to a temporary directory | Restore verified; the backup job pings the dead-man's switch |
| 3.6 | OpenTofu state backend with client-side encryption | Init, apply and state pull round trip |
| 3.7 | 2.5 GbE link troubleshooting from the new install | Link up at 2.5 Gbit/s, or fallback F1 recorded |

Steps 3.5 and 3.6 need accounts the owner creates (Backblaze, healthchecks.io, a Telegram bot) and an elevated PowerShell on the workstation for Hyper-V. They are asked for when 3.4 is done.

## Rollback

| Situation | Action |
|---|---|
| The installer fails | `reboot-on-error` is off, so the error stays on the console. The old system is gone by then; the fix is to boot the same stick again by hand, or to attach a monitor and read the error |
| The new system does not come back on the network | Console on Node 1. The answer file's network settings are the first suspect |
| Ansible breaks SSH | The recovery key is authorised by the installer and stays authorised; the owner's physical console remains |

## Secrets created in this phase

| Secret | Where |
|---|---|
| Root password of the hypervisor (break-glass, console and web interface) | Generated on the workstation, stored SOPS-encrypted in the private repository; the owner copies it to the password manager. Only its hash enters the install media, which is deleted after use |
