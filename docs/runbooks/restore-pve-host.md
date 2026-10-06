# Runbook: rebuild the hypervisor

Use this when `pve1` (Node 1) must be installed again: a planned reinstall of the running host, or a rebuild after its disk or the whole machine was lost. It takes the host from an empty disk to the configured state with its backups armed.

To restore single files on a healthy host, use [restore-host-config.md](restore-host-config.md). For the other loss scenarios, start at [DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md).

Status: the planned path (section 2A) installed this host on 2026-10-06, with the media script as it was that day. Sections 2B and 2C and the rebuild after a loss have not been rehearsed.

## What a reinstall destroys

The installer erases the whole system disk: the Proxmox system, the cluster database and the thin pool with every guest disk. No guests exist today. What is not in Git comes back from the nightly backup in section 6.

## Before starting

| Needed | How |
|---|---|
| The workstation on one of its two addresses (192.168.1.196 or 192.168.1.197), in the repository, in WSL | The hypervisor and the router admit nothing else |
| The private repository on `main`, clean, in step with GitHub | `just private-status` |
| An operator session | `just session-start` |
| The session's agent for plain `ssh` commands in this terminal | `export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"` |
| The pinned Ansible collections (a fresh clone has none) | `just ansible-deps` |
| For section 2A step 1: the backup server VM running | Elevated PowerShell on the workstation, see section 2B step 1 |
| For sections 2B and 5: the backup server VM running and the management window open | Elevated PowerShell on the workstation, see section 2B steps 1 and 2 |
| For sections 2B and 2C, and whenever an install fails: a monitor and a keyboard on Node 1 | A failed install stays on the console with its error |
| Node 1's onboard port cabled to router port lan1 | That port already carries the management network untagged and the servers network tagged. No router change is needed |

## 1. Choose the install path

| Situation | Path |
|---|---|
| The host runs and answers on 10.0.10.10 | 2A: built on the host, booted once into the installer, nobody touches the machine |
| The host is dead; the backup server VM runs | 2B: image built on the backup server VM, stick written on the workstation, booted by hand |
| No builder at all (both machines were lost), or the tooling fails | 2C: stock installer, answered by hand |

If the disk, the stick or the board was replaced, read "Replaced hardware" at the end first.

## 2A. Planned reinstall of a running host

The USB stick recorded in `private/proxmox/pve1.yaml` (`pve_usb_stick_serial`) must be in the machine.

1. Take a backup now and check that it arrived:

   ```sh
   ssh ops@10.0.10.10 sudo systemctl start pbs-host-backup.service
   ssh ops@10.0.10.10 sudo pbs-host-restore list
   ```

   The list contains a snapshot from this minute. Note its name.

2. Let the installer's own tool check the answer file:

   ```sh
   just pve-media validate
   ```

   Expected last line: `answer file valid; nothing was built or written`.

3. Build the image on the host, write it to the stick and arm a one-time boot:

   ```sh
   just pve-media prepare
   ```

   Expected: `stick content verified`, then `media ready and armed for one boot`. The script refuses a device that is not the recorded USB stick, is mounted or is in use.

4. Reboot into the installer. From here the system disk is erased:

   ```sh
   just pve-media reboot
   ```

   Expected: `rebooting into the installer at <time>`. The install took about five minutes on 2026-10-06.

5. Wait until the new system answers:

   ```sh
   ping -c 3 10.0.10.10
   ```

Continue with section 3. The stick still carries the installer; the first task of `just pve-apply` in section 4 overwrites it and removes the boot entry. That task knows only the stick recorded in `private/proxmox/pve1.yaml`. A stick named through `PVE_USB_SERIAL` for this one run is not overwritten: pull it and erase it by hand.

## 2B. Dead host: image built on the backup server VM

1. On the workstation, in an elevated PowerShell, start the VM if it is off:

   ```powershell
   Start-VM pbs1
   ```

2. In the same PowerShell, in the repository, open the management window:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

   Expected: `management window: OPEN (SSH from WSL through port 2222)`. Keep it open until section 5 is done.

3. In WSL, check the answer file on the builder:

   ```sh
   PVE_BUILDER=pbs1 just pve-media validate
   ```

   Expected last line: `answer file valid; nothing was built or written`.

4. Build the image. The first build downloads the stock installer to the VM and verifies its checksum:

   ```sh
   PVE_BUILDER=pbs1 just pve-media iso
   ```

   Expected: `image ready and verified: /mnt/f/homelab/iso/pve1-auto.iso`. On Windows that is `F:\homelab\iso\pve1-auto.iso`.

5. Write the image raw to a USB stick on the workstation. This step is manual; the repository has no recipe for it.

6. Delete the image. It embeds the hash of the root password:

   ```sh
   rm /mnt/f/homelab/iso/pve1-auto.iso
   ```

7. Put the stick into Node 1, power on, press the firmware's boot-menu key and choose the stick's UEFI entry. The install asks nothing and reboots by itself.

8. Deal with the stick when the machine reboots:

   | Stick | Action |
   |---|---|
   | The one recorded in `private/proxmox/pve1.yaml` | Leave it in. The first task of `just pve-apply` overwrites the installer on it |
   | Any other | Pull it and erase it. It reinstalls a machine it is booted on, and it carries the password hash |

9. Wait until the new system answers:

   ```sh
   ping -c 3 10.0.10.10
   ```

Continue with section 3.

## 2C. Manual fallback: the stock installer

Not rehearsed. Use it when neither builder exists.

1. Download the stock image named by `ISO_NAME` in `scripts/pve/build-install-media.sh` from the address in `ISO_URL`, and compare its SHA-256 sum with `ISO_SHA256` in the same script.
2. Write it raw to a USB stick and boot Node 1 from it in UEFI mode.
3. Give these answers. They are the values of `infrastructure/proxmox/answer.toml.tmpl`.

   | Question | Answer | Key in the template |
   |---|---|---|
   | Target disk | The system SSD | `filter.ID_SERIAL` |
   | Filesystem | ext4 | `filesystem` |
   | Advanced disk options: maxroot | 20 | `lvm.maxroot` |
   | Advanced disk options: swapsize | 4 | `lvm.swapsize` |
   | Advanced disk options: minfree | 4 | `lvm.minfree` |
   | Country | India | `country` |
   | Time zone | Asia/Kolkata | `timezone` |
   | Keyboard layout | U.S. English | `keyboard` |
   | Root password | The output of `just reveal private/proxmox/pve1.sops.yaml pve_root_password` | `root-password-hashed` |
   | E-mail | The value of `pve_mailto` in `private/proxmox/pve1.yaml` | `mailto` |
   | Management interface | The onboard gigabit port (Realtek RTL8168), not the 2.5 GbE card | `filter.ID_MODEL_ID` |
   | Hostname (FQDN) | `pve1.112511.xyz` | `fqdn` |
   | Address | `10.0.10.10/24` | `cidr` |
   | Gateway | `10.0.10.1` | `gateway` |
   | DNS server | `10.0.10.1` | `dns` |

4. The interactive installer authorises no SSH key. After the reboot, install the session's key for root once, from the workstation. It asks for the root password:

   ```sh
   ssh-keygen -R 10.0.10.10
   ssh-copy-id root@10.0.10.10
   ```

Continue with section 3, step 2.

## 3. First contact

1. Remove the old host key. The reinstalled host has a new one:

   ```sh
   ssh-keygen -R 10.0.10.10
   ```

2. Run the bootstrap play. It connects as root with the key the installer authorised, creates the operator account `ops`, authorises the keys of the private inventory for it and closes root login:

   ```sh
   just pve-bootstrap
   ```

   Ansible shows the new host key and asks once; answer `yes`. Expected: the recap shows `failed=0`.

This play runs once. A second run cannot log in, because the first one closed root login. That is the intended state.

## 4. Configure the host

```sh
just pve-apply
```

The play applies everything from Git: it makes the install stick inert, sets the repositories, SSH, time, memory and log settings, the bridges (under a revert timer), the firewall, the exporters, the roles, users and access entries, and notifications.

**On a rebuilt host this run stops at its very end, on purpose.** The last task finds no storage entry `pbs-node2` on the host while the private repository records an encryption key for it. It fails with:

```
pve1 has no storage entry pbs-node2, but the private repository records an encryption key for it:
this host was rebuilt and its backups are NOT armed. Everything else in this play has been applied.
Run `just pve-backup-init` now; it creates the entry with the recorded key and arms the backups.
```

The play refuses to end green while a host that had backups has none. Nothing is wrong; continue with section 5.

## 5. Tokens and the backup path

The backup server VM must run and the management window must be open (section 2B, steps 1 and 2): `just pve-backup-init` logs in to the backup server.

1. Issue the API tokens. They lived in the erased cluster database:

   ```sh
   just pve-tokens
   ```

   Expected: `Issued ...; secrets stored in private/proxmox/tokens.sops.yaml`. The secrets are never displayed.

2. Connect the host to the backup server:

   ```sh
   just pve-backup-init
   ```

   The play creates the storage entry with the **recorded** encryption key from `private/proxmox/backup-keys.sops.yaml`. It never generates a new key when one is recorded, so the old backups stay readable. Expected: `Backup path ready and checked: storage pbs-node2 on pve1 is active through <address>` and `The recorded encryption key is in use.`

3. Commit and push the private repository. The token secrets changed:

   ```sh
   git -C private add proxmox/tokens.sops.yaml
   git -C private commit -m "Re-issue the hypervisor API tokens after the rebuild"
   git -C private push
   just private-status
   ```

4. Run the host play again. It must end clean:

   ```sh
   just pve-apply
   ```

   Expected: `failed=0`. A further run shows `changed=0`.

## 6. Restore what is not in Git

On a rebuilt host, name the snapshot. `latest` is refused when the newest snapshot was taken after the install and older ones exist, because the newest one is then the rebuilt, empty host.

1. Log in and become root:

   ```sh
   ssh ops@10.0.10.10
   sudo -i
   ```

2. List the snapshots and pick one from before the loss:

   ```sh
   pbs-host-restore list
   ```

3. Restore the archive into a new directory. The command never writes onto a live path:

   ```sh
   pbs-host-restore host/pve1-host/<time of the snapshot> etc.pxar /tmp/restore-etc
   ```

   The archives are `etc.pxar` (`/etc`, including the view of `/etc/pve`), `root.pxar` (`/root`) and `pve-cluster.pxar` (one consistent `config.db`).

4. Compare and copy back single files, then remove the directory. The steps and examples are in [restore-host-config.md](restore-host-config.md).

**The whole cluster database.** Putting the restored `config.db` in place brings back everything the database held at once: guest configurations, users, tokens, TOTP enrolments, storage entries. The procedure is: stop `pve-cluster`, remove `config.db-wal` and `config.db-shm`, install the single restored `config.db`, start `pve-cluster`. The exact commands, and the plays to run afterwards, are in [restore-host-config.md](restore-host-config.md), section "Restore the whole cluster database". It has not been done on a live host yet. Today, with no guests, nothing requires it: sections 4, 5 and 7 rebuild the same state.

## 7. Second factor

A rebuilt host does not require a second factor until every password user has enrolled one, so the owner is never locked out.

1. Open `https://10.0.10.10:8006` from the workstation.
2. Log in as the administrator account (`pve_admin_user` in `infrastructure/ansible/playbooks/group_vars/proxmox.yaml`) and enrol TOTP. The password:

   ```sh
   just reveal private/ansible/inventory/host_vars/pve1/secrets.sops.yaml pve_admin_password
   ```

3. Log in as root in the realm `pam` and enrol TOTP. The password:

   ```sh
   just reveal private/proxmox/pve1.sops.yaml pve_root_password
   ```

4. Switch the requirement back on:

   ```sh
   just pve-apply
   ```

   The task "Realms require a second factor" reports a change for both realms.

5. Close the management window on the workstation, in an elevated PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1
   ```

   Expected: `management window: closed.`

## How to know it worked

| Check | Expected |
|---|---|
| `just pve-apply`, run once more | `failed=0`, `changed=0` |
| `ssh ops@10.0.10.10 sudo pvesm status --storage pbs-node2` | A line with `pbs-node2`, `pbs`, `active` |
| `ssh ops@10.0.10.10 systemctl is-active pbs-host-backup.timer pbs-failover.timer pbs-keepalive.service` | `active` three times |
| `ssh ops@10.0.10.10 sudo systemctl start pbs-host-backup.service`, then `ssh ops@10.0.10.10 sudo pbs-host-restore list` | A new snapshot from this minute |
| `ssh ops@10.0.10.10 sudo pve-firewall status` | Enabled and running |
| `ssh root@10.0.10.10` | `Permission denied` |
| `just test-fences` | `fences hold: <n> probes, all as expected`. The run of 2026-10-07 passed with the management window open ([phase-3.md](../phases/phase-3.md)) |

Record the date, the path taken and the time in the drill log of [DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md).

The later steps of a full rebuild (Talos VMs through `just tofu pve apply`, the cluster, Argo CD) are not built yet.

## Replaced hardware

The answer file selects the install disk by serial number and the network port by chip. An image built for other hardware finds no match and stops on the console.

| What changed | What to edit | Where |
|---|---|---|
| The system disk | `pve_disk_serial`. The line must keep the form `pve_disk_serial: "<value>"` | `private/proxmox/pve1.yaml`; commit the private repository |
| The install stick (path 2A only) | `pve_usb_stick_serial`. `PVE_USB_SERIAL` in the environment replaces it for one run of `just pve-media prepare`, but `just pve-apply` then does not overwrite that stick | `private/proxmox/pve1.yaml`; commit the private repository |
| The board, with an onboard port that is not a Realtek RTL8168 | `filter.ID_MODEL_ID` | `infrastructure/proxmox/answer.toml.tmpl`, by pull request |
| The board, with other port names | `pve_nic_lan` and `pve_nic_p2p`; the names are path-based | `infrastructure/ansible/playbooks/group_vars/proxmox.yaml`, by pull request |

The disk's value is the udev property `ID_SERIAL`. Read it from any Linux booted on that machine, for example the debug shell of the stock installer:

```sh
udevadm info --query=property --name=/dev/sda | grep ID_SERIAL=
```

Serial numbers go into the private repository only, never into a public file.

## If something fails

| Symptom | Cause and action |
|---|---|
| `just pve-media prepare`: `stick with serial ... not found` | The recorded stick is not in the machine. Plug it in, or record the new stick (see "Replaced hardware") |
| `just pve-media reboot`: `no one-time boot entry armed` | `prepare` did not finish. Run it again |
| `PVE_BUILDER=pbs1 just pve-media ...` cannot connect | The VM is off or the management window is closed: section 2B, steps 1 and 2 |
| The installer stops on the console | The disk serial or the port filter matches nothing. See "Replaced hardware". With path 2A a power cycle boots whatever is on the disk, because the boot entry was for one boot only |
| `just pve-bootstrap`: the host key has changed | `ssh-keygen -R 10.0.10.10`, then run it again |
| `just pve-bootstrap`: root is refused | The play already ran, or the stock installer was used and no key is authorised (section 2C, step 4) |
| `just pve-apply` stops in the bridge change | Wait three minutes. The host restores its previous interfaces file by itself (`journalctl -t homelab`). Then run the play again |
| `just pve-backup-init` cannot reach `pbs1` | The VM is off or the management window is closed: section 2B, steps 1 and 2 |
| `just pve-backup-init`: `accepts no connection on port 8007` | Ansible reached the VM, but the hypervisor reaches port 8007 on no path: not over the direct link and not through the workstation's forward. Check that the workstation holds 192.168.1.196 or 192.168.1.197, run `pbs-vm.ps1 -Manage` again (it restores the forward and its rules), look at `just test-fences`, then run the play again. The hypervisor was not changed |
| `just pve-backup-init`: the key `differs from the one recorded` | Nothing was overwritten. Follow the message: remove the storage entry and run the play again, which creates it with the recorded key |
