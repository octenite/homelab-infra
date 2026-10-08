# Component: Proxmox Backup Server (VM on the workstation)

## Purpose

The local backup target: nightly backups of the hypervisor's configuration and, from Phase 5, images of the guests, deduplicated and verified. It runs as a Hyper-V VM on Node 2, the Windows workstation, because Node 1 has no memory to spare and a backup server should not live on the host it protects. It is the second copy of the 3-2-1 rule. The off-site copy is a separate component and does not exist yet.

## Architecture

- `pbs1`, Proxmox Backup Server 4.2, Hyper-V Generation 1, 2 vCPU, 4 GiB fixed memory. Checkpoints are disabled. The VM is started by hand (owner decision 2026-10-06). A clean shutdown follows the host.
- Disks under `F:\homelab\pbs1\disks`: `system.vhdx` (32 GiB, IDE) and `datastore.vhdx` (128 GiB, fixed size, SCSI).
- The datastore disk is attached exactly when no install medium is in the drive. With two disks present the installer's disk names are not stable, and it once installed onto the datastore disk.
- Boot order: system disk first, then DVD. An empty system disk falls through to the installer. An installed one never re-enters it.
- Datastore `pbs1`: one GPT partition, ext4, found by its filesystem or partition label, mounted at `/mnt/datastore/pbs1` with `defaults,nofail,x-systemd.device-timeout=10s`. The VM boots without the disk instead of stopping in emergency mode.
- Jobs: prune daily (keep 7 daily, 4 weekly, 3 monthly), garbage collection `sun 03:00`, verification monthly, snapshots verified again after 30 days.
- Notifications: the product's own system sends job failures and update notices to the owner's Telegram chat through a webhook target. The datastore uses notification mode `notification-system`.
- Memory budget on the workstation: Windows about 6 GiB, WSL capped at 5 GB, the VM 4 GiB fixed.

Network legs of the VM:

| Leg | Switch | VM address | Workstation side | Carries |
|---|---|---|---|---|
| `nat` | `pbs-nat`, internal, with a NAT for 10.0.98.0/29 | 10.0.98.3/29, gateway 10.0.98.1 | 10.0.98.1 | Internet egress and the two forwarded ports |
| `p2p` | `p2p`, external, on the direct-link adapter | 10.0.99.3/29, no gateway | 10.0.99.2 | The primary path from the hypervisor (10.0.99.1) |

The direct-link adapter is the USB 2.5 GbE adapter, or the laptop's own gigabit port when the USB adapter has no link. The `p2p` leg is configured on a run with an adapter present.

Paths from the hypervisor to port 8007:

| Order | Address | How |
|---|---|---|
| 1 | 10.0.99.3 | Direct link |
| 2 | 192.168.1.196 | Workstation dock port, forwarded to the VM (E14) |
| 3 | 192.168.1.197 | Workstation Wi-Fi, forwarded to the VM (E14) |

The hypervisor picks the first path on which the backup server itself answers. See [proxmox.md](proxmox.md), Backup.

### Why Generation 1

The Proxmox installer's early environment has no synthetic Hyper-V storage or keyboard driver. On a Generation 2 VM it finds neither its DVD nor the console keyboard (seen 2026-10-06). The emulated IDE and PS/2 devices of a Generation 1 VM work, and the installed system uses the synthetic drivers. Secure Boot is therefore unavailable (X7).

## Dependencies

- The workstation: switched on, Hyper-V enabled, a volume `F:`, and the VM started by hand.
- WSL2 with an open operator session for every recipe. Ansible reaches the VM only through the management window (see Fences).
- The hypervisor: `just pbs-media` builds the install image there. With the hypervisor down no recipe can build the image.
- Nothing in the lab depends on the backup server.

## Deployment

Recipes run in WSL in the repository with a session open (`just session-start`). `pbs-vm.ps1` runs in an elevated PowerShell in the repository directory. Every run of it converges the switches, NAT, VM, disks, port ACLs, firewall rules, port forwards and the WSL memory cap, and prints only what it changed.

1. Build the install image. It lands in `F:\homelab\iso\pbs1-auto.iso`.

   ```sh
   just pbs-media
   ```

   Expect `image ready and verified: /mnt/f/homelab/iso/pbs1-auto.iso`.

2. Create the VM and start the unattended install. The datastore disk stays detached during the install.

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Iso F:\homelab\iso\pbs1-auto.iso
   ```

   The installer needs no input. Wait until the VM console shows the login prompt of the installed system.

3. Detach the medium. This also deletes the image (it embeds the root password hash) and attaches the datastore disk.

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Eject
   ```

4. Open the management window.

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

   Expect `management window: OPEN (SSH from WSL through port 2222). Close it with a plain run when the work is done.`

5. First contact, once, as root: operator account, keys, root login over SSH closed.

   ```sh
   just pbs-bootstrap
   ```

6. Configure the server from Git.

   ```sh
   just pbs-apply
   ```

   A second run reports `changed=0`.

7. Connect the hypervisor: backup user and token, storage entry, encryption key. Attended. Commit the private repository afterwards.

   ```sh
   just pve-backup-init
   ```

   Expect `Backup path ready and checked`.

8. Close the management window with a plain run.

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1
   ```

   Expect `management window: closed.`

9. Run the deny test (see Fences).

   ```sh
   just test-fences
   ```

Later changes: steps 4, 6 and 8.

## Configuration

| What | Where |
|---|---|
| VM size, disk sizes, switch names, addresses, the adapters' static MAC addresses, port ACLs, firewall rules, forwards, WSL cap | `scripts/node2/pbs-vm.ps1`, settings block |
| Install layout, address, keys | `infrastructure/pbs/answer.toml.tmpl`, rendered by `scripts/pbs/build-install-iso.sh` |
| Root password | private repository, `proxmox/pbs1.sops.yaml` |
| Host policy: repositories, SSH, direct-link address, guest firewall, datastore, jobs, notifications | `infrastructure/ansible/roles/pbs_host/` |
| Datastore name and path, retention, who may reach the VM | `infrastructure/ansible/playbooks/group_vars/pbs.yaml` |
| Job schedules, the recreate flag | `infrastructure/ansible/roles/pbs_host/defaults/main.yaml` |
| How Ansible reaches the VM (WSL gateway, port 2222, host key alias `pbs1`) | private inventory, `ansible/inventory/hosts.yaml` |
| Telegram bot token and chat | private inventory, `ansible/inventory/group_vars/all/` |

Unattended upgrades install Debian security updates only. Proxmox packages are upgraded by hand.

## Fences

### Why block rules

On the workstation many Windows services shared one `svchost` process (X25): the registry value `SvcHostSplitThresholdInKB` had been raised far above the installed memory. A built-in allow rule scoped to one service in that process then admitted every port the process listened on, from any source, and the port forwards listened in that process. Address-scoped allow rules alone restricted nothing (found by the deny test of 2026-10-06).

Block rules win over allow rules. `pbs-vm.ps1` maintains the rules below by content on every run, reads each one back after creating it, and removes any other rule named `homelab-*`. Rules name addresses, never interfaces: a rule bound to an interface stops matching when the virtual adapter is created again.

| Rule | Action | Port | Source | Present |
|---|---|---|---|---|
| `homelab-block-direct-link` | Block | any | 10.0.99.0 to 10.0.99.7 | always |
| `homelab-block-backup-vm` | Block | any | 10.0.98.2 to 10.0.98.6 | always |
| `homelab-pbs1-8007-others` | Block | TCP 8007 | every address except 10.0.10.10; with `-Away` every address | always |
| `homelab-pbs1-ssh-others` | Block | TCP 2222 | every address outside 172.16.0.0/12 | always |
| `homelab-pbs1-8007` | Allow | TCP 8007 | 10.0.10.10 (E14) | not with `-Away` |
| `homelab-pbs1-ssh-wsl` | Allow | TCP 2222 | 172.16.0.0/12, the range WSL takes its network from | only with `-Manage` |

The remedy at the root, the default split threshold, was applied on 2026-10-07 by `scripts/node2/workstation.ps1` (`docs/phases/phase-3.md`). The block rules stay as the second layer.

### Port forwards

| Listens on | Forwards to | Present |
|---|---|---|
| 0.0.0.0:8007 | 10.0.98.3:8007 | not with `-Away` |
| 0.0.0.0:2222 | 10.0.98.3:22 | only with `-Manage` |

Both listen on every address of the workstation. The firewall rules above are what limits them. A forwarded connection reaches the VM from 10.0.98.1, so the guest cannot tell the hypervisor from any other source: the workstation's rules are the control on this path.

### Away from home

The backup port is admitted by source address. When the laptop travels it accepts a route to 10.0.10.10 through the Tailscale tunnel (Phase R, `docs/phases/phase-r-plan.md`), and that address then no longer proves which path a packet took. So the forward does not exist on the road:

| Action | Command (elevated PowerShell) | Effect |
|---|---|---|
| Before leaving | `powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Away` | Removes the 8007 forward and `homelab-pbs1-8007`; `homelab-pbs1-8007-others` blocks the port for every source. The management window is closed. `-Away` cannot be combined with another switch |
| Back at home | `powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1` | Restores the forward and the rule for the hypervisor |

No mode is stored. The last line of the script's output names the state of the backup port. `scripts\node2\travel.ps1` (step R.9) will call both forms; until it exists they are run by hand. While the laptop is away the hypervisor has no backup target, and the dead-man's switch reports the missed runs.

### Management window

SSH to the VM exists only while the management window is open (X26).

| Action | Command (elevated PowerShell) | Effect |
|---|---|---|
| Open | `powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage` | Adds the 2222 forward and `homelab-pbs1-ssh-wsl` |
| Close | `powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1` | Removes both |

The window is opened and closed by hand. Nothing closes it after a time. `just pbs-bootstrap`, `just pbs-apply`, `just pve-backup-init` and `PVE_BUILDER=pbs1 just pve-media iso` need it open. `just test-fences` prints which state is live: `management window: open` or `management window: closed`.

### Port ACLs on the VM's adapters

The second layer. They belong to an adapter and vanish with it, so every run asserts them and removes any other entry.

| Adapter | Entries, both directions |
|---|---|
| `nat` | Deny 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10. Allow 10.0.98.1 |
| `p2p` | Deny everything. Allow 10.0.99.1 |

The VM's NAT traffic leaves with the workstation's address, which the router trusts (E1 to E3). The `nat` ACL is what keeps that trust from the VM: it reaches no private address except its gateway. 100.64.0.0/10 is the range of Tailscale addresses: with the Tailscale client on the workstation, the VM's NAT traffic would otherwise leave through the tunnel as the laptop. IPv6 is unbound from both host-side adapters, so link-local addresses offer no way around the address-based rules. The host side of `p2p` is pinned to the Public profile.

### Guest firewall

nftables in the VM, input policy drop:

| Accepts | From |
|---|---|
| TCP 8007 and ping | 10.0.98.1 (the forward) and 10.0.99.1 (the hypervisor) |
| TCP 22 | 10.0.98.1 (the forward) |

Forwarding is dropped. Output is accepted.

### What is not restricted

The VM's outbound traffic to the internet is not restricted. It needs package repositories and the notification endpoint, and no allow-list exists in the guest or on the workstation. Only the private ranges are closed to it, by the `nat` port ACL.

### Deny test

```sh
just test-fences
```

Run it in WSL with a session open. It only opens TCP connections and sends pings. It ends with `fences hold: <n> probes, all as expected`, or with `FENCES BROKEN` and a non-zero exit code when one probe disagrees.

| From | Expected |
|---|---|
| Hypervisor, direct link | Workstation 10.0.99.2: no port answers, no ping. VM 10.0.99.3: 8007 open, ping answered, 22, 80 and 111 filtered |
| Hypervisor, home network | Each address the workstation holds: 8007 open; 22, 445, 2222 and 3389 closed |
| Router | 8007 and 2222 on the workstation: silent |
| WSL | 8007 closed on the workstation's addresses, on the WSL gateway and on 10.0.99.2 |
| Backup VM (only while the window is open) | Nothing on the hypervisor's direct-link address, nothing on the workstation, nothing in a private range; 9.9.9.9 port 53 and download.proxmox.com port 443 open |

After `pbs-vm.ps1 -Away` the test is `just test-fences away`: the same probes, with 8007 on the workstation's home addresses expected closed.

Status: passed on 2026-10-07 with the window open and with it closed; the results are in `docs/phases/phase-3.md`. Before the rules above were applied on the workstation, 12 probes had disagreed. The away form and the probe of a Tailscale address were added in Phase R, step R.3, and are proven in that step's record.

## Security considerations

- The VM lives on an unencrypted disk of a personal laptop (X23, X7). Readable there: the system disk with the root password hash, the SSH host keys, the server's token database and the Telegram bot token.
- Backups are encrypted on the hypervisor before they leave it. The key is on the hypervisor and, as SOPS ciphertext, in the private repository. It is never readable on the workstation.
- SSH: key-only, the operator account only, and only through the management window. Root has no SSH path and no authorised key. Root's way in is the VM console with the password.
- `root@pam` has no second factor yet. Open item for the owner.
- The install image embeds the root password hash. `-Eject` deletes the workstation's copy. `just pbs-media` removes every copy on the hypervisor when it ends.
- The hypervisor's user and token on the backup server are granted `DatastoreBackup` on the datastore `pbs1` only.

## Backup

The datastore is the backup. Today it is the only copy of the hypervisor's backups outside the hypervisor. The VM's system disk is not backed up: it is rebuilt from Git.

## Restore

Restoring data from this server: [restore-host-config.md](../runbooks/restore-host-config.md). Guest restores follow in Phase 5. A lost or replaced workstation, including a lost datastore: [restore-workstation.md](../runbooks/restore-workstation.md).

### Rebuild the system, keep the datastore

`-WipeDatastore` is never part of a rebuild. It deletes the datastore disk and every backup on it.

Needed: the workstation with the datastore disk file intact, the hypervisor up, a session open.

1. Build the image.

   ```sh
   just pbs-media
   ```

2. Stop the VM, then replace the system disk with an empty one and install. The datastore disk is detached, not changed.

   ```powershell
   Stop-VM pbs1
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -WipeSystem -Yes 'delete pbs1 system' -Iso F:\homelab\iso\pbs1-auto.iso
   ```

3. When the console shows the login prompt of the installed system, detach the medium and open the management window.

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Eject
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

4. The VM has a new SSH host key. Remove the old one, then bootstrap and configure.

   ```sh
   ssh-keygen -R pbs1
   just pbs-bootstrap
   just pbs-apply
   ```

   The role mounts the kept disk by its label and registers the datastore again with its content (`--reuse-datastore true`). It creates the jobs again.

5. Repair the hypervisor's side. Attended.

   ```sh
   just pve-backup-init
   ```

   The backup server gets a new token. The hypervisor's existing storage entry gets the new token and the new certificate fingerprint. The encryption key is not touched. Commit the private repository.

6. Close the window, then run the deny test.

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1
   ```

   ```sh
   just test-fences
   ```

It worked when `just pve-backup-init` ends with `Backup path ready and checked` and `sudo pbs-host-restore list` on the hypervisor shows the snapshots from before the rebuild.

`-Recreate -Yes 'recreate pbs1'` is not a reinstall. It removes the VM definition and keeps both disk files, so an installed system disk boots again as it was. Use it when the definition itself is wrong or lost.

This sequence has not been rehearsed end to end. It counts as verified once a rehearsal is recorded in the phase record.

### What the role refuses

| Refusal | Meaning | Action |
|---|---|---|
| The server lists the datastore, but the mount point holds no chunk store | The disk was replaced or wiped. Every backup on it is gone | Attach the right disk. Only if the loss is intended, run once with the flag below: the server forgets the old datastore, keeps its jobs and access entries, and creates an empty one |
| The disk has a partition on which no filesystem is recognised | A first setup was interrupted before formatting, or a datastore's filesystem is damaged | Interrupted first setup: run once with the flag. Disk that held backups: do not. Try a filesystem repair first, as the message says |
| The disk holds something that is not the datastore | A stray disk, or the wrong disk attached | Read the `lsblk` output in the message. No flag overrides this |

The flag is `pbs_host_datastore_recreate`, off by default. `just pbs-apply` hands extra arguments to the play. Run it with a session and the management window open:

```sh
just pbs-apply -e pbs_host_datastore_recreate=true
```

Warning: with the flag the role formats a partition without a filesystem and creates an empty datastore over a missing chunk store. Use it for one run, and only when the backups on that disk are known to be gone or never existed.

## Troubleshooting

| Symptom | Check |
|---|---|
| The hypervisor cannot reach the backup server | Is the VM running: `Get-VM pbs1`. Then `sudo pbs-target` on the hypervisor prints the address in use. `just test-fences` shows which path answers |
| `just pbs-apply` or `just pbs-bootstrap` cannot connect | The management window is closed, or the VM is off. Run `pbs-vm.ps1 -Manage` |
| SSH reports a changed host key for `pbs1` | The system was reinstalled: `ssh-keygen -R pbs1` |
| The installer stops with "no device with valid ISO found", or the console cannot send keys | The VM is Generation 2. Rebuild the definition: `pbs-vm.ps1 -Recreate -Yes 'recreate pbs1'` |
| The VM boots into an initramfs shell complaining about `pbs-OLD` | The system disk carried an older install. Stop the VM, then `pbs-vm.ps1 -WipeSystem -Yes 'delete pbs1 system' -Iso ...`, then `-Eject` |
| The play stops with "no disk carries the label pbs1 and no empty disk exists" | The datastore disk is not attached: an install medium is still in the drive. Run `pbs-vm.ps1 -Eject` |
| The play refuses the datastore disk | See "What the role refuses" |
| The VM has no internet | `Get-NetNat pbs-nat` and `Get-VMNetworkAdapterAcl -VMName pbs1` on the workstation |
| The direct link is not used | `Get-VMSwitch p2p` and the adapter's link on the workstation. The `p2p` adapter is added to the VM only while the VM is off |
| No Telegram message arrives | `/etc/proxmox-backup/notifications.cfg` in the VM, and `just pbs-apply` |

## Removal

Stop the VM first: `Stop-VM pbs1`. Everything `pbs-vm.ps1` creates on the workstation:

| Item | Remove with |
|---|---|
| VM `pbs1` (its port ACLs go with it) | `Remove-VM pbs1` |
| Disk files and VM directory `F:\homelab\pbs1`. Deleting `disks\datastore.vhdx` deletes every local backup | Delete the directory |
| Install image `F:\homelab\iso\pbs1-auto.iso`, if one is left | Delete the file |
| NAT `pbs-nat` | `Remove-NetNat pbs-nat` |
| Switch `pbs-nat` with the host address 10.0.98.1/29 | `Remove-VMSwitch pbs-nat` |
| Switch `p2p` with the host address 10.0.99.2/29 | `Remove-VMSwitch p2p` |
| Firewall rules `homelab-block-direct-link`, `homelab-block-backup-vm`, `homelab-pbs1-8007-others`, `homelab-pbs1-ssh-others`, `homelab-pbs1-8007`, `homelab-pbs1-ssh-wsl` | `Get-NetFirewallRule -Name 'homelab-*' \| Remove-NetFirewallRule` |
| Forward 8007 | `netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8007` |
| Forward 2222, if the window is open | `netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=2222` |
| The line `memory=5GB` in `%USERPROFILE%\.wslconfig`. The script only rewrites an existing `memory` line | Edit the file, then `wsl --shutdown` |
| IP Helper service set to start automatically | Leave it, unless nothing else uses port forwards |

On the other hosts: remove rule E14 from the router's firewall template and apply it; on the hypervisor remove the storage entry `pbs-node2` and the units `pbs-failover.timer`, `pbs-host-backup.timer` and `pbs-keepalive.service`; remove the `pbs` group from the private inventory. No recipe does this.
