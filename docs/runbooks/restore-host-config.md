# Runbook: restore the hypervisor's configuration from the backup server

Use this when a file under `/etc`, `/etc/pve` or `/root` on `pve1` was lost or changed wrongly, or after a rebuild of the host ([restore-pve-host.md](restore-pve-host.md), section 6) to bring back what is not in Git. The rebuild itself is the unattended install plus Ansible; this runbook only restores data.

## What the backup holds

`pbs-host-backup.timer` runs every night at 02:30. Each snapshot is encrypted on the hypervisor before it leaves, and holds three archives. Installer images (`*.iso`) are left out.

| Archive | Content |
|---|---|
| `etc.pxar` | `/etc`, including the view of `/etc/pve` |
| `pve-cluster.pxar` | One file, `config.db`: a consistent copy of the cluster database, taken with SQLite's own online backup and integrity-checked before the upload |
| `root.pxar` | `/root` |

The only copy is the datastore of the backup server VM on the workstation. There is no off-site copy.

## Before starting

| Needed | How |
|---|---|
| The hypervisor is up, the host role is applied and the storage entry `pbs-node2` exists | `just pve-apply` ends clean. The role installs `pbs-host-restore` and its credentials only when the entry exists |
| On a rebuilt hypervisor: the storage entry and the encryption key | `just pve-backup-init`. It creates the entry with the key recorded in the private repository. Nothing is placed by hand |
| The backup server VM is running on the workstation | It is started by hand. Either path works: the direct link, or the fallback through the workstation's port forward. `pbs-target` picks the one that answers |
| A session and its agent, for `ssh` | `just session-start`, then `export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"` |

A restore does not need the key on the workstation. To see the recorded key, for example to compare it with the password manager's copy:

```sh
just reveal private/proxmox/backup-keys.sops.yaml pbs-node2 key
```

Without the third argument the output is the whole entry, not the key.

## Restore single files

On the hypervisor, as root:

1. Log in:

   ```sh
   ssh ops@10.0.10.10
   sudo -i
   ```

2. List the snapshots:

   ```sh
   pbs-host-restore list
   ```

3. Restore one archive into a directory that does not exist yet. The command never writes onto a live path:

   ```sh
   pbs-host-restore latest etc.pxar /tmp/restore-etc
   ```

   Expected last line: `restored etc.pxar of host/pve1-host/<time> into /tmp/restore-etc`.

   On a rebuilt host `latest` is refused when the newest snapshot was taken after the install and older ones exist. Name a snapshot from the list instead:

   ```sh
   pbs-host-restore host/pve1-host/<time> etc.pxar /tmp/restore-etc
   ```

4. Compare, then copy only what is needed. For example a guest configuration:

   ```sh
   diff -r /tmp/restore-etc/pve/qemu-server /etc/pve/qemu-server
   cp /tmp/restore-etc/pve/qemu-server/101.conf /etc/pve/qemu-server/
   ```

   A file that Ansible manages is rewritten by the next `just pve-apply`. Correct such a file in Git, not by copying.

5. Remove the restored copy. It holds password hashes and private keys:

   ```sh
   rm -rf /tmp/restore-etc
   ```

## Restore the whole cluster database

Status: the archive was restored into a scratch directory and checked on 2026-10-07. The swap below has **not** been done on a live host. It closes with a drill once the first guest exists (Phase 5).

Use it after a rebuild when the guest configurations and everything else in the database are wanted back at once. Today, with no guests, it is not needed: the plays rebuild the same state.

What comes back is the database as it was at the snapshot:

| Content | Consequence |
|---|---|
| Guest configurations, pools, storage entries | As at the snapshot |
| Users, password hashes of the `pve` realm, access entries | As at the snapshot. The next `just pve-apply` converges roles and access entries to Git |
| TOTP enrolments and the realm requirement | Back. No new enrolment is needed |
| API tokens | The tokens of the snapshot. If `just pve-tokens` has run since, the secrets in the private repository no longer match (step 9) |
| The storage entry `pbs-node2` with its key and token secret | As at the snapshot. `just pve-backup-init` checks the key and repairs the rest (step 10) |

On the hypervisor, as root:

1. Restore the archive while the cluster filesystem is still up; the encryption key lives on it:

   ```sh
   pbs-host-restore host/pve1-host/<time> pve-cluster.pxar /tmp/restore-cluster
   ```

2. Check the restored database:

   ```sh
   sqlite3 /tmp/restore-cluster/config.db 'pragma integrity_check;'
   ```

   Expected: `ok`. Stop here on any other answer.

3. Stop the cluster filesystem. `/etc/pve` is empty until step 7:

   ```sh
   systemctl stop pve-cluster
   ```

4. Keep the present database aside:

   ```sh
   cp -a /var/lib/pve-cluster /root/pve-cluster.before-restore
   ```

5. Remove the write-ahead log and its index. They belong to the database that is being replaced:

   ```sh
   rm -f /var/lib/pve-cluster/config.db-wal /var/lib/pve-cluster/config.db-shm
   ```

6. Install the single restored file:

   ```sh
   install -m 0600 -o root -g root /tmp/restore-cluster/config.db /var/lib/pve-cluster/config.db
   ```

7. Start the cluster filesystem:

   ```sh
   systemctl start pve-cluster
   ```

8. Check that it serves the restored state:

   ```sh
   ls /etc/pve
   pvesm status
   ```

Then, from the workstation:

9. If `just pve-tokens` has run since the snapshot was taken, issue the tokens again. For each token in `pve_tokens` (`infrastructure/ansible/playbooks/group_vars/proxmox.yaml`), on the hypervisor:

   ```sh
   sudo pveum user token remove <userid> <tokenid>
   ```

   Then on the workstation, and commit the private repository afterwards:

   ```sh
   just pve-tokens
   ```

10. Repair the backup path and converge the host. `just pve-backup-init` needs the management window:

    ```sh
    just pve-backup-init
    just pve-apply
    ```

11. On the hypervisor, remove both copies once step 10 ended clean:

    ```sh
    sudo rm -rf /tmp/restore-cluster /root/pve-cluster.before-restore
    ```

## How to know it worked

| Restore | Check |
|---|---|
| Single files | The copied file is in place and equals the restored one; `just pve-apply` ends with `failed=0` |
| Whole database | `sudo pvesm status --storage pbs-node2` on the hypervisor shows `active`; `just pve-apply` ends with `failed=0`, and a further run with `changed=0` |

## Verification record

| Date | What | Result |
|---|---|---|
| 2026-10-06 | First backup (30 s, 1.4 GiB before the ISO exclusion), second backup (0.3 s, 6.4 MiB), restore of `etc.pxar` from the latest snapshot to a temporary directory | 768 files restored; `hostname`, `network/interfaces`, `pve/storage.cfg`, `pve/firewall/cluster.fw`, `chrony/chrony.conf` identical to the live files; over the fallback path |
| 2026-10-06, after the key rotation | Backup with the new key over the direct link (storage on `pbs1.internal`, failover had picked 10.0.99.3), restore of `etc.pxar` | 768 files, the same five files identical |
| 2026-10-07, after the review fixes | Backup over the direct link (10.0.99.3), then restore of all three archives into scratch directories | Restored `config.db` passes `pragma integrity_check` (`ok`), holds 42 rows in its tree table like the live database, and contains `storage.cfg`, `user.cfg` and `datacenter.cfg`. Restored `/etc` files equal the live ones. The staging directory was removed after the backup. A second restore into an existing directory was refused |

Not verified yet: the whole-database swap on a host; any restore on a rebuilt host, including the refusal of `latest` there.

## Failure modes

| Symptom | Cause and action |
|---|---|
| `pbs-host-restore: command not found`, or `/etc/homelab/backup.conf` is missing | The storage entry does not exist, so the role set up nothing. Run `just pve-backup-init` (backup server VM running, management window open) |
| Every command fails with a connection error, and `journalctl -t homelab` shows `backup server unreachable on every path (is the VM running?)` | Nothing answers on port 8007. Decide between the next two rows with `curl --insecure --max-time 4 https://192.168.1.196:8007/` on the hypervisor (192.168.1.197 when the workstation is on Wi-Fi) |
| The backup VM is off: that `curl` fails at once, because the workstation's port forward accepts the connection and nothing is behind it | Start the VM on the workstation, in an elevated PowerShell: `Start-VM pbs1`. After a minute `pbs-target` on the hypervisor prints the address in use |
| The workstation is away (out of the house, asleep or shut down): that `curl` times out on both addresses | Nothing on the hypervisor can fix it, and no other copy of the backups exists. Wait for the workstation, start the VM, then restore. The nightly backup fails meanwhile and the dead-man's switch reports the missing ping. Catch up with `sudo systemctl start pbs-host-backup.service` |
| `pbs-target` prints a workstation address although the cable is in | The direct link is down on one side. The restore still works over the fallback path. Check `ethtool enp2s0` and `systemctl status pbs-keepalive.service` on the hypervisor, `Get-VMSwitch p2p` and the USB adapter on the workstation |
| `permission check failed` | The token's or the user's entry on the backup server is missing. Both must hold `DatastoreBackup` on `/datastore/pbs1`. `just pve-backup-init` adds what is missing |
| A certificate or fingerprint error | The backup server was reinstalled and has a new certificate. `just pve-backup-init` writes the new fingerprint and token secret into the existing entry |
| `unable to open key file`, or decryption errors | The key under `/etc/pve/priv/storage/pbs-node2.enc` is missing or is not the one the backups were made with. Run `just pve-backup-init`: it compares the host's key with the recorded one and stops with instructions when they differ. Never create the entry by hand with a generated key |
| `refusing: <directory> exists` | The destination must be a new directory |
| `refusing 'latest'` | The host was rebuilt and the newest snapshot is the rebuilt host. Name an older snapshot from `pbs-host-restore list` |
| `no finished snapshot` | No backup has completed for this host. Run `systemctl start pbs-host-backup.service` and read its journal |
