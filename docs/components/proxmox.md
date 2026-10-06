# Component: Proxmox VE host

## Purpose

Node 1 runs Proxmox VE and hosts the Talos VMs. It is the single physical host of the platform. Nothing about it is highly available. Its recovery is a reinstall from Git plus a restore.

## Architecture

- One host, `pve1`, Proxmox VE 9.2, in the management network at 10.0.10.10 on the onboard gigabit port.
- Bridges: `vmbr0` on the onboard port (`enp3s0`), VLAN-aware, host address untagged and the servers VLAN 50 tagged for guests. `vmbr1` on the 2.5 GbE port (`enp2s0`) with 10.0.99.1/29, the direct link to the workstation for backups, no guests. IP forwarding is off: the host does not route between them.
- Storage: ext4 root, swap as a safety net, and an LVM thin pool for VM disks and, later, Kubernetes volumes.
- Time: chrony with the router as the only source. The host serves time to the two Talos node addresses only (E13), from its own clock when the router has none.
- Metrics: `node_exporter` (9100) and `smartctl_exporter` (9633) from the upstream Ansible collection, bound to the management address. A timer adds thin-pool usage through the textfile collector. The SMART exporter runs with the `disk` group and `CAP_SYS_RAWIO`, nothing else.
- Notifications: the product's own system sends every notification to the owner's Telegram chat through a webhook target. The bot token sits in the host's private notification file and in the private repository.
- Updates: unattended upgrades install Debian security updates only, without a reboot. Proxmox packages follow [upgrade-pve.md](../runbooks/upgrade-pve.md).

Host firewall (pve-firewall, inbound policy DROP). Exception IDs are those of [ARCHITECTURE.md](../ARCHITECTURE.md) section 6.

| ID | Source | Admitted |
|---|---|---|
| E2 | Workstation: 192.168.1.196 (dock) and 192.168.1.197 (Wi-Fi) | TCP 22 and 8006, ping |
| E6 | Talos workers: 10.0.50.21, 10.0.50.22 | TCP 8006 |
| E7 | Talos workers | TCP 9100 and 9633 |
| E13 | Talos nodes: 10.0.50.11, 10.0.50.21 | UDP 123 |
| - | Router 10.0.10.1 | ping |

Nothing else is admitted. No rule admits the console ports: the web console runs over 8006. pve-firewall would admit the host's own subnets to its management ports through a built-in set, so the role drops 10.0.10.0/24 and 10.0.99.0/29 on ports 22, 8006, 3128, 5900 to 5999 and 60000 to 60050 after the accept rules (X10).

## Dependencies

- The router: default route, DNS and time.
- The workstation: every recipe runs there, in WSL, with a session open (`just session-start`).
- The backup server VM, for backups only. The host runs without it.

## Deployment

The host is installed unattended and configured by Ansible. Nothing is configured by hand.

1. Build install media and boot it. See Install media below.
2. After a reinstall the host has a new SSH host key. Remove the old one:

   ```sh
   ssh-keygen -R 10.0.10.10
   ```

3. First contact, once, as root with the key the installer authorised: operator account, keys, root login over SSH closed.

   ```sh
   just pve-bootstrap
   ```

4. Configure the host from Git. Idempotent.

   ```sh
   just pve-apply
   ```

   On a rebuilt host this run stops at its very end and says to run `just pve-backup-init`. Everything else has been applied by then.

5. Issue the API tokens that are missing. Attended. Their secrets go straight into `private/proxmox/tokens.sops.yaml`.

   ```sh
   just pve-tokens
   ```

6. Connect the host to the backup server. Attended. The backup server VM must be running and its management window open ([pbs.md](pbs.md), Fences).

   ```sh
   just pve-backup-init
   ```

7. Run the host play again. It must end without a failure, and a further run reports `changed=0`.

   ```sh
   just pve-apply
   ```

8. The owner enrols TOTP in the web interface for the administrator account and for `root@pam`. The next `just pve-apply` switches the requirement on.

Commit the private repository after steps 5 and 6.

### Install media

```sh
just pve-media <mode>
```

| Mode | What it does | What it changes |
|---|---|---|
| `validate` | Renders the answer file in memory and lets the installer's own tool check it | Nothing is built or written |
| `iso` | Builds the image on a builder host, copies it to the workstation and compares checksums | `F:\homelab\iso\pve1-auto.iso` on the workstation |
| `prepare` | Builds the image on the running hypervisor, writes it to the recorded USB stick, reads it back, arms a one-time boot entry `pve-install` | The stick is overwritten |
| `reboot` | Reboots the hypervisor into the armed installer. Refuses when no one-time boot is armed | The host is reinstalled: its system disk is erased |

Two situations:

| Situation | Sequence |
|---|---|
| Planned reinstall, the host runs | `just pve-media prepare`, then `just pve-media reboot`. Nobody touches the machine |
| The host is dead | Open the backup server's management window, then `PVE_BUILDER=pbs1 just pve-media iso`. Write the image to a USB stick on the workstation, boot Node 1 from it with the boot-menu key |

Facts to know before building:

- The answer file is `infrastructure/proxmox/answer.toml.tmpl`. The values it needs come from the private repository: `proxmox/pve1.sops.yaml` (root password), `proxmox/pve1.yaml` (disk serial, stick serial, notification address) and the authorised keys in `ansible/inventory/group_vars/all/ssh.yaml`.
- The installer selects the system disk by serial number. A replacement disk needs its serial in `private/proxmox/pve1.yaml` before the image is built, or the installer stops at the console.
- `prepare` runs on the hypervisor only. It refuses a device that is not the recorded USB stick, is mounted, or is in use.
- Every image embeds the root password hash. The build removes its copies on the builder when it ends. Delete `F:\homelab\iso\pve1-auto.iso` by hand once the stick is written.
- No script writes the image to a stick on the workstation, and booting a hand-written stick needs the boot-menu key. Both are manual steps.

### Leftover install media

A stick that still carries the installer is a loaded reinstall: booted by mistake it erases the system disk without asking. The first task of the host role therefore makes it inert on every `just pve-apply`:

- It overwrites the installer image with zeros on the stick whose serial is recorded in `private/proxmox/pve1.yaml`, and only while that stick still carries the installer.
- It removes every firmware boot entry named `pve-install`.

A different stick, such as one written on the workstation for a recovery, is not touched. Pull it out after the install.

## Configuration

| What | Where |
|---|---|
| Install layout, address, keys | `infrastructure/proxmox/answer.toml.tmpl` |
| Host policy: install media, repositories, SSH, time, memory, logs, bridges, firewall, metrics, access, backups, notifications | `infrastructure/ansible/roles/pve_host/` |
| Addresses the rules refer to, roles, users, pool, ACLs, token list, realms that require a second factor, backup settings, exporter versions | `infrastructure/ansible/playbooks/group_vars/proxmox.yaml` |
| Firewall rule list, time sources, revert time of a bridge change | `infrastructure/ansible/roles/pve_host/defaults/main.yaml` |
| Root password | private repository, `proxmox/pve1.sops.yaml` |
| Disk and stick serial numbers, notification address | private repository, `proxmox/pve1.yaml` |
| Administrator password, ping URL of the backup check | private repository, `ansible/inventory/host_vars/pve1/secrets.sops.yaml` |
| API token secrets, backup token secret | private repository, `proxmox/tokens.sops.yaml` |
| Backup encryption key | private repository, `proxmox/backup-keys.sops.yaml` |

`/etc/pve` is a cluster filesystem that refuses permission changes and atomic replacement. The role compares its files there and writes them in place.

A change to the bridges is guarded. The role parses the new interfaces file, arms a transient timer (`homelab-net-revert.timer`) that restores the previous file, applies the change detached from the SSH session, and disarms the timer only after the host answers again with the expected VLANs and bridges. A change that is not confirmed within three minutes is undone by the host itself.

What follows Git, and what does not:

| Object | Behaviour |
|---|---|
| Role privilege lists | Follow Git in both directions |
| ACL entries of the users and tokens named in Git | Follow Git in both directions: an entry Git no longer grants is removed |
| Users and tokens | Only ever added. One that Git does not know stops the play |
| Administrator password | Set once, at creation. Rotation is by hand ([secrets-register.md](../security/secrets-register.md)) |
| Operator account's SSH keys | Follow the inventory on every run |

### What `just pve-apply` refuses

The play stops on purpose in these cases. Restarts that earlier tasks requested still happen.

| Message contains | Cause | What to do |
|---|---|---|
| `Unmanaged user(s) in the pve realm` | A user exists on the host that Git does not name | Add it to `pve_users` through a pull request, or remove it: `sudo pveum user delete <user>` |
| `Unmanaged token(s)` | A token exists on the host that Git does not name | Add it to `pve_tokens`, or remove it: `sudo pveum user token remove <user> <token>` |
| `The key list must hold at least two keys, one of them loaded in the agent` | The key list in the private inventory would lock the operator out | Keep two keys in `private/ansible/inventory/group_vars/all/ssh.yaml` and open a session that holds one of them. Replacing a key: [operator-key-compromised.md](../runbooks/operator-key-compromised.md) |
| `an earlier network change was never confirmed and its revert timer is still armed` | A run was cut off after it changed the bridges. Nothing was changed by this run | Wait up to three minutes. `journalctl -t homelab` on the host shows the restore. Run the play again |
| `the bridges were NOT confirmed` | The host did not come back as expected after a bridge change | Same: wait for the restore, check with `sudo ifquery --check -a`, run the play again |
| `its backups are NOT armed` | The host was rebuilt: a key is recorded but the storage entry is missing. Everything else has been applied | `just pve-backup-init`, then `just pve-apply` again |
| `the nightly backup is not armed` | `pbs-host-backup.timer` is not enabled and active | Read the failure above it in the output, fix it, run the play again |

## Security considerations

- SSH is key-only, for the operator account `ops` only, on the management address only, from the workstation's two addresses only. `ops` has sudo without a password.
- Root has no SSH path: `PermitRootLogin no` and `AllowUsers ops`. Root's key file is Proxmox's own link into `/etc/pve`, and the role removes the operator's keys from it. Root's way in is the console with the password.
- The operator's keys are replaced by `just pve-apply` from the inventory list. The list must hold at least two keys, one of them loaded in the agent.
- `root@pam` with its password is break-glass for the console and the web interface. The password is in the private repository and the password manager.
- The account named by `pve_admin_user` is the only holder of `Administrator`. Its password is set once, through standard input.
- Second factor: the realms `pve` and `pam` require TOTP. The role switches the requirement on only once every user of the realm who holds a password has enrolled a TOTP, so a rebuilt host first lets the owner enrol. Only TOTP counts: a hardware key or recovery keys alone do not. Automation users hold no password and use tokens, which the requirement never affects.
- Automation uses privilege-separated API tokens of dedicated users with custom roles (`TerraformProvisioner`, `KubernetesCSI`) or `PVEAuditor`. Tokens live 12 months. Rotation: remove the token on the host, run `just pve-tokens`, update the consumer.
- `TerraformProvisioner` has no `Sys.Modify`. Its network grant is the single path `/sdn/zones/localnetwork/vmbr0/50`: a grant on the bridge itself would also permit a guest adapter without a tag, which lands in the management VLAN.
- The CPU receives no microcode updates any more. One vulnerability stays open (X13).

### Lost second factor

Use this when the TOTP device of the administrator account or of `root@pam` is lost.

With a recovery key (Two Factor, Add, Recovery Keys): log in with the password and one recovery key, remove the lost TOTP entry, add a new one. Nothing else is needed.

Without a recovery key:

1. Log in as the operator. The realm is `pve` for the administrator account and `pam` for `root@pam`.

   ```sh
   export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"
   ssh ops@10.0.10.10
   ```

2. Lift the realm's requirement.

   ```sh
   sudo pveum realm modify <realm> --delete tfa
   ```

3. Delete the user's lost entry.

   ```sh
   sudo pveum user tfa list <user>
   sudo pveum user tfa delete <user>
   ```

4. Log in to the web interface with the password alone. Enrol a new TOTP. Add recovery keys and store them in the password manager.
5. Put the requirement back.

   ```sh
   just pve-apply
   ```

   The task "Realms require a second factor" reports a change.

Between steps 2 and 5 every user of that realm logs in with a password alone. Do the steps in one sitting. This procedure has not been rehearsed on the host yet.

## Backup

The host configuration is reproducible from Git. What is not (the cluster filesystem's state, guest configurations, `/root`) is backed up every night to the backup server, encrypted on the host.

| Unit | Does |
|---|---|
| `pbs-host-backup.timer` | 02:30 every night, with up to ten minutes of random delay: runs `/usr/local/bin/pbs-host-backup` |
| `pbs-failover.timer` | Every five minutes: runs `/usr/local/bin/pbs-target` |
| `pbs-keepalive.service` | One ping a second to 10.0.99.3 |

| Archive | Content |
|---|---|
| `etc.pxar` | `/etc`, including the `/etc/pve` view |
| `pve-cluster.pxar` | One file, `config.db`: a consistent copy of the live cluster database taken with SQLite's own backup and integrity-checked before upload |
| `root.pxar` | `/root` |

Files named `*.iso` are left out of every archive.

- Path: the storage entry `pbs-node2` names the server `pbs1.internal`, a line in `/etc/hosts`. Proxmox forbids changing a storage's server, so `pbs-target` rewrites that one line: 10.0.99.3 first, else 192.168.1.196, else 192.168.1.197. A path counts as up when an HTTPS request to port 8007 gets through. A bare connect is not enough: the workstation's port forward accepts connections while the VM is off. With nothing answering, the last choice stays.
- Keep-alive: the workstation's USB 2.5 GbE adapter powers its link down after about ten idle seconds and does not bring it back. One packet a second has kept it up since 2026-10-06. The 24-hour soak that confirms it is still open ([phase-3.md](../phases/phase-3.md)).
- Dead-man's switch: a successful backup pings a healthchecks.io check. Any failure exits before the ping. The ping URL is a secret in `/etc/homelab/backup.secret`, root only.
- Encryption key: `/etc/pve/priv/storage/pbs-node2.enc` on the host, and recorded in the private repository (`proxmox/backup-keys.sops.yaml`, key `pbs-node2`). A copy belongs in the owner's password manager.

`just pve-backup-init` sets the path up and repairs it. It never rotates or regenerates a recorded key.

| Situation | What it does |
|---|---|
| First setup, no key recorded | Creates the backup user and token and the storage entry with a new key, and records token and key |
| Hypervisor rebuilt: key recorded, no storage entry | Creates the storage entry with the recorded key |
| Backup server rebuilt: storage entry exists | Issues a new token and sets the entry's token and certificate fingerprint |
| The host's key differs from the recorded key | Stops. Nothing is overwritten |

It ends by checking that the storage is active.

## Restore

The step-by-step runbook is [restore-pve-host.md](../runbooks/restore-pve-host.md). The order after the loss of the host, as built:

1. Workstation with the repository, the private repository on `main` (`just setup`, `just private-status`) and a session.
2. Install media and boot: Install media above, "The host is dead". Manual: the boot-menu key.
3. Deployment steps 2 to 7. `just pve-backup-init` creates the storage entry with the recorded key, so the old backups stay readable.
4. Restore what is needed into a scratch directory. The command never writes onto a live path.

   ```sh
   sudo pbs-host-restore list
   sudo pbs-host-restore <snapshot> etc.pxar /tmp/restore-etc
   ```

   `latest` instead of a snapshot name is refused on a rebuilt host when the newest snapshot is newer than the install and older ones exist: name the snapshot. Details and the cluster database: [restore-host-config.md](../runbooks/restore-host-config.md).
5. The owner enrols TOTP again for the administrator account and `root@pam`, then `just pve-apply`.

Later phases add `just tofu pve apply`, Talos and Argo CD. The whole-platform order is in [DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| SSH or the web interface is unreachable from the workstation | The workstation must hold 192.168.1.196 (dock) or 192.168.1.197 (Wi-Fi). On the host: `sudo pve-firewall status` |
| `ssh root@10.0.10.10` is refused | By design. Log in as `ops` |
| A device in the management network reaches a host port | It must not: `sudo iptables -S PVEFW-HOST-IN` shows the drops |
| Time is wrong | `chronyc sources`. The router is the only source |
| The play fails on a file under `/etc/pve` | The file must be written in place, not copied or replaced |
| The play failed in the bridge change | Wait three minutes: the host restores its previous file (`journalctl -t homelab`). Then `sudo ifquery --check -a` and run the play again |
| The play stops at its end | See "What `just pve-apply` refuses" |
| The nightly backup failed | The backup server VM is started by hand: is it running. `sudo pbs-target` prints the address in use. `systemctl status pbs-host-backup.service` and `journalctl -t homelab` |
| The direct link is down | `sudo ethtool enp2s0` for link and speed, `systemctl status pbs-keepalive`. The bridge `vmbr1` stays up without a link, and backups use the fallback path |
| The second factor is lost | "Lost second factor" above |
| The host boots into the installer | An install stick is still plugged in. Pull it out. The role only wipes the recorded stick |

## Removal

Not applicable: it is the only host.
