# Runbook: restore the hypervisor's configuration from the backup server

Scope: the nightly host-configuration backup of `pve1` (`/etc` including `/etc/pve`, `/var/lib/pve-cluster`, `/root`), stored encrypted on the backup server VM. The authoritative rebuild path is the unattended install plus Ansible ([DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md)); this restore is for the pieces that are not in Git: the cluster filesystem's state, guest configurations, and files under `/root`.

## Prerequisites

- The hypervisor is up with its storage entry `pbs-node2` (created by `just pve-backup-init`) and the host role applied (`just pve-apply`), which installs the credentials and the `pbs-host-restore` command.
- The backup server VM is running on the workstation (it is started by hand). Either path works: the direct link or the fallback through the workstation's port forward; `pbs-target` picks the one that answers.
- On a rebuilt hypervisor, the encryption key must be put back first: `just reveal private/proxmox/backup-keys.sops.yaml pbs-node2` gives the key JSON; write it to `/etc/pve/priv/storage/pbs-node2.enc` (mode 0600) before `just pve-backup-init`, or the init play's `--encryption-key autogen` would make a new key that cannot read the old backups. If the entry has to be created by hand, `pvesm add ... --encryption-key <path to the key file>`: the option takes a file path, and a value passed instead is echoed back in the error message.

## Procedure

As the operator on the hypervisor (`ssh ops@10.0.10.10`, then `sudo -i`):

1. List what exists:

   ```
   pbs-host-restore list
   ```

2. Restore one archive into an empty directory (never onto the live tree):

   ```
   pbs-host-restore latest etc.pxar /tmp/restore-etc
   ```

   The other archives are `pve-cluster.pxar` (the cluster database, `/var/lib/pve-cluster`) and `root.pxar`.

3. Inspect, then copy only what is needed, for example a guest configuration:

   ```
   diff -r /tmp/restore-etc/pve/qemu-server /etc/pve/qemu-server
   cp /tmp/restore-etc/pve/qemu-server/101.conf /etc/pve/qemu-server/
   ```

   The cluster database (`pve-cluster.pxar`) is restored whole only with `pve-cluster` stopped, and only when `/etc/pve` is empty on a rebuilt host: stop `pve-cluster`, replace `/var/lib/pve-cluster/config.db`, start it again.

4. Remove the restored copy: `rm -rf /tmp/restore-etc`.

## Verification record

| Date | What | Result |
|---|---|---|
| 2026-10-06 | First backup (30 s, 1.4 GiB before the ISO exclusion), second backup (0.3 s, 6.4 MiB), restore of `etc.pxar` from the latest snapshot to a temporary directory | 768 files restored; `hostname`, `network/interfaces`, `pve/storage.cfg`, `pve/firewall/cluster.fw`, `chrony/chrony.conf` identical to the live files; over the fallback path |
| 2026-10-06, after the key rotation | Backup with the new key over the direct link (storage on `pbs1.internal`, failover had picked 10.0.99.3), restore of `etc.pxar` | 768 files, the same five files identical |

## Failure modes

| Symptom | Cause and action |
|---|---|
| `pbs-target` prints the fallback address although the cable is in | The direct link is down on one side: `ethtool enp2s0` on the hypervisor, `Get-VMSwitch p2p` and the adapter on the workstation |
| `permission check failed` | The token's or the user's entry on the backup server is missing; `proxmox-backup-manager acl list` there. Both must hold `DatastoreBackup` on `/datastore/pbs1` |
| `unable to open key file` or decryption errors | The key under `/etc/pve/priv/storage/pbs-node2.enc` is not the one the backups were made with; restore it from the private repository |
| Connection refused on 8007 | The VM is off: start it on the workstation (`Start-VM pbs1`) |
