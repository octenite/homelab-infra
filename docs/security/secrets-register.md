# Secrets register

One row per secret or credential: where it lives, what uses it, how it is rotated, and what a leak costs. Values are never written here. Custody rules and their reasoning are in [ARCHITECTURE.md](../ARCHITECTURE.md) section 9.

Last checked against the code: 2026-10-07, commit `397a592`.

Owner of every row: the repository owner, who is the only administrator.

## How to read it

- Paths that start with `private/` are in the private repository. Only file names and key names appear here.
- Commands run in WSL, in the repository, with a session open (`just session-start`), unless a step says otherwise.
- `just reveal <file> <key> [subkey]` prints one value. `just secret-set <file> <key>` stores one value typed at a hidden prompt.
- After every change under `private/`: commit and push it, then run `just private-status`. It must report that `private/` is on main, clean and in step with GitHub.
- "Password manager" is the owner's. Its entries cannot be checked from the repository. Entries the owner has not confirmed are listed under [Open](#open).
- The hypervisor is reached with `ssh ops@10.0.10.10`. The account `ops` has sudo without a password. Root has no SSH login on pve1 or pbs1.
- pbs1 is reached only while the VM runs and the management window is open. The VM is started by hand (`Start-VM pbs1`). Open the window in an elevated PowerShell on the workstation, and close it with a plain run of the same script when the work is done:

  ```
  powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
  powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1
  ```

  With the window open, from WSL:

  ```
  ssh -o HostKeyAlias=pbs1 -p 2222 "ops@$(ip -4 route show default | awk '{print $3; exit}')"
  ```

## 1. Operator keys

| Secret | Created | Lives in | Used by | Rotation | If it leaks |
|---|---|---|---|---|---|
| age operator key | 2026-10-05 | Workstation, WSL: `~/.config/sops/age/operator.age`, passphrase-encrypted. A decrypted copy exists in memory only, at `/dev/shm/homelab-session/age.key`, while a session is open (12 hours at most) | Every recipe that reads or writes a SOPS file: the plays, `just reveal`, `just secret-set`, `just tofu`, `just pve-media`, `just pbs-media` | Yearly. At once if the laptop is lost or the passphrase may be known. [bootstrap-keys.md](../runbooks/bootstrap-keys.md), "Rotation and loss" | With the passphrase and a copy of the private repository: every secret stored in SOPS. Re-encrypting the files does not undo that. Every such secret in this register is rotated |
| age recovery key | 2026-10-05 | Password manager and two paper copies. Not on the workstation in normal work | The owner, offline, in drills and when the operator key is gone | On exposure, and after any use outside a drill: new key, `sops updatekeys -y` on every file, both paper copies replaced ([bootstrap-keys.md](../runbooks/bootstrap-keys.md)) | Same as the operator key |
| Lab SSH key | 2026-10-05 | Private half: workstation, WSL, `~/.ssh/homelab_ed25519`, passphrase-protected. `just session-start` loads it into the agent at `~/.ssh/homelab-agent.sock` for the session. Public half: `private/ansible/inventory/group_vars/all/ssh.yaml`, list `openwrt_ssh_authorized_keys` | Every play, `just luci`, `just test-fences`, the install-media builders. Authorised on five hosts: for `root` on the router and both access points, for `ops` on pve1 and pbs1 | Yearly. At once if the laptop is lost. [R1](#r1-replace-an-ssh-key) | With the passphrase: root on the three network devices and full control of pve1 and pbs1. pve1 holds the backup encryption key and the backup token. The hosts accept SSH from the workstation's two addresses only (E2), and pbs1 only through the workstation |
| Recovery SSH key | 2026-10-05 | Private half and its passphrase: password manager only. Public half: the same list, so the same five hosts and accounts | The owner, when the lab key is lost | On use and on exposure. [R1](#r1-replace-an-ssh-key) | Same as the lab key |
| GitHub CLI token | Before the project | Workstation, WSL, in a readable file. Known gap against exception X23 (see `docs/phases/phase-1.md`) | `git push` and `gh` for both repositories | The owner replaces it with a fine-grained token limited to the two repositories, with an expiry (backlog B6) | Push access to both repositories. The ruleset on `main` still requires a pull request and green checks. The private repository holds ciphertext and identifiers only |

## 2. Network devices

| Secret | Created | Lives in | Used by | Rotation | If it leaks |
|---|---|---|---|---|---|
| OpenWrt root passwords (router, both access points) | Before the project | The owner. Not in the private repository. No play reads or sets them | Login on the serial console and in LuCI. LuCI listens on the loopback address and is reached through `just luci`. SSH does not accept a password. This is the way in if both SSH keys are lost | Yearly, and on exposure: `passwd` on each device (`ssh root@192.168.1.53`, `ssh root@10.0.10.2`, `ssh root@10.0.10.3`), then the password manager | Nothing over the network by itself. With physical access to a serial console, or together with an SSH key: full control of that device |
| Wi-Fi keys: main, guest, IoT, and the key of the disabled WDS link | 2026-10-05 (main and IoT generated; guest is the key in use before the split) | `private/ansible/inventory/group_vars/openwrt/wifi.sops.yaml` and the per-device files `private/ansible/inventory/host_vars/<device>/secrets.sops.yaml` (`router-m30`, `ap1`, `ap2`). Variables: `openwrt_wifi_key_main`, `openwrt_wifi_key_guest`, `openwrt_wifi_key_iot`, `openwrt_wifi_key_wds`. On each device in its wireless configuration | The wireless templates of the three devices; every Wi-Fi client | Main and IoT: when a device that knew them is lost or sold. Guest: at will. [R2](#r2-change-a-wi-fi-key) | Main: a device in range joins the trusted network. IoT: it joins the IoT network. Guest: internet access only |
| Router and access-point configuration backups | 2026-10-05 | `private/openwrt/backups/<date>/`, SOPS-encrypted | Restore of a device ([restore-openwrt.md](../runbooks/restore-openwrt.md)) | Not rotated. A new backup is taken before each phase that changes a device (`private/openwrt/backups/README.md`) | They contain the Wi-Fi keys, the SSH host keys and the root password hashes of the three devices. Rotate those |

## 3. Hypervisor (pve1)

| Secret | Created | Lives in | Used by | Rotation | If it leaks |
|---|---|---|---|---|---|
| `root@pam` password | 2026-10-06 (generated for the reinstall) | `private/proxmox/pve1.sops.yaml`, key `pve_root_password`. Password manager. Its hash is embedded in every install image that `just pve-media` builds | The owner, break-glass: the physical console, and the web interface on port 8006 together with the TOTP | Yearly, and on exposure. [R3](#r3-change-a-root-password) | Console login for someone at the machine. The web interface also needs the workstation's address (E2) and the second factor |
| Administrator password, `octenite-admin@pve` | 2026-10-06 | `private/ansible/inventory/host_vars/pve1/secrets.sops.yaml`, key `pve_admin_password`. Password manager | The owner's daily login to the web interface, with TOTP. It is the only account that holds `Administrator`. `just pve-apply` sets the password once, when the account is created, and never changes it afterwards | Yearly, and on exposure. [R4](#r4-change-the-administrator-password) | Administrator on the hypervisor, but only from the workstation's address and with the second factor |
| TOTP secrets of `root@pam` and `octenite-admin@pve` | 2026-10-06 (enrolled by the owner) | The owner's password manager or authenticator only. Never in either repository. The server's copy is in the cluster filesystem on pve1 and so in the encrypted nightly backup | Second step of every password login. Both realms require it | On a lost phone or on exposure: the lost-second-factor steps in [proxmox.md](../components/proxmox.md), then enrol again in the web interface and run `just pve-apply`, which puts the requirement back | The second factor of that account is worth nothing. With the password it is a full login |
| TOTP recovery keys of the same two accounts | Created and stored (owner, 2026-10-06) | Password manager only (web interface: Two Factor, Add, Recovery Keys) | The owner, when the phone is lost | After use: create a new set | Same as the TOTP secret |
| API tokens `terraform@pve!tofu`, `kubernetes-csi@pve!csi`, `prometheus@pve!exporter`, `drift@pve!weekly` | 2026-10-06 | `private/proxmox/tokens.sops.yaml`, one entry per full token name with `secret`, `issued` and `expires`. Example: `just reveal private/proxmox/tokens.sops.yaml 'terraform@pve!tofu' secret` | No consumer is deployed yet. Planned: OpenTofu on the workstation (Phase 5), the CSI plugin (Phase 7), the exporter (Phase 9), the weekly drift job | They expire 365 days after issue. Earlier on exposure. [R5](#r5-replace-a-hypervisor-api-token) | `tofu`: create and change VMs in the pool `talos`, allocate on the two storages, attach to VLAN 50. It has no `Sys.Modify`. `csi`: disks on `local-lvm`. `exporter` and `weekly`: read everything, change nothing. The API answers only the workstation (E2) and the Talos workers (E6) |

## 4. Backup path

| Secret | Created | Lives in | Used by | Rotation | If it leaks |
|---|---|---|---|---|---|
| Backup server `root@pam` password | 2026-10-06 (generated for the install) | `private/proxmox/pbs1.sops.yaml`, key `pbs_root_password`. Password manager (owner to confirm). Its hash is embedded in the install image that `just pbs-media` builds, until `pbs-vm.ps1 -Eject` deletes the image | The owner: the VM console in Hyper-V, and the web interface on port 8007. No second factor is enrolled (backlog B24) | Yearly, and on exposure. [R3](#r3-change-a-root-password) | Full control of the backup server for anyone who reaches its console or port 8007: backups can be deleted, and the Telegram bot token read. Backups cannot be read: they are encrypted on the hypervisor. Port 8007 answers the hypervisor and the workstation itself |
| Backup token `pve1@pbs!backup` | 2026-10-06 | `private/proxmox/tokens.sops.yaml`, entry `pve1@pbs!backup` (no expiry). On pve1: `/etc/pve/priv/storage/pbs-node2.pw` and `/etc/homelab/backup.secret`, both root only | The storage entry `pbs-node2`, `pbs-host-backup` and `pbs-host-restore` on pve1. User and token hold `DatastoreBackup` on `/datastore/pbs1` | On exposure. A rebuild of the backup server replaces it as well. [R6](#r6-replace-the-backup-token) | Writing backups into the datastore and reading the hypervisor's own snapshots as ciphertext. It cannot prune or remove the datastore |
| Backup encryption key `pbs-node2` | 2026-10-06 (generated with the storage entry; replaced the same day after the first key was displayed in a session transcript, see `docs/phases/phase-3.md`) | pve1: `/etc/pve/priv/storage/pbs-node2.enc`. `private/proxmox/backup-keys.sops.yaml`, entry `pbs-node2` with the sub-keys `key` and `host`. Password manager (owner to confirm): `just reveal private/proxmox/backup-keys.sops.yaml pbs-node2 key` | Every backup and restore on pve1: `pbs-host-backup`, `pbs-host-restore`, and the storage entry for guest backups from Phase 5 | Never by a play. See [the key is not rotated](#the-backup-encryption-key-is-not-rotated) | Every backup made with it is readable by whoever also obtains the backup data. The host backup contains `/etc`, the cluster database with token and TOTP secrets, and `/root`. Rotate everything in sections 3 and 4 |

## 5. OpenTofu state

The backend is not initialised yet: `private/opentofu/backend.hcl` (bucket, region, endpoint; identifiers, not secrets) does not exist, and no state exists. See `docs/phases/phase-3.md`, gate item G2.

| Secret | Created | Lives in | Used by | Rotation | If it leaks |
|---|---|---|---|---|---|
| State passphrase | 2026-10-06 (generated) | `private/opentofu/b2.sops.yaml`, key `tofu_state_passphrase`. Password manager | `just tofu <root> <command>`: `scripts/tofu/child.sh` passes it to OpenTofu, which encrypts every state and plan file before it leaves the workstation | Not rotated routinely. No rotation path is built: the root has one key provider and no fallback, so a changed passphrase cannot read existing state (backlog B29). While no state exists, `just secret-set private/opentofu/b2.sops.yaml tofu_state_passphrase` is the whole change | With the bucket keys or a state copy: the state in the clear. From Phase 5 the state holds the Talos secrets |
| Backblaze B2 application key for the state bucket | 2026-10-06 (owner) | `private/opentofu/b2.sops.yaml`, keys `b2_key_id` and `b2_application_key` | `just tofu`: the S3 backend, and the fetch of the encrypted state copy into `private/opentofu/state-copies/` | Yearly, and on exposure. [R7](#r7-replace-the-b2-application-key) | Reading, overwriting and deleting the state objects. They are ciphertext |

## 6. Notifications and monitoring

| Secret | Created | Lives in | Used by | Rotation | If it leaks |
|---|---|---|---|---|---|
| Telegram bot token | 2026-10-06 (owner, BotFather) | `private/ansible/inventory/group_vars/all/notify.sops.yaml`, key `telegram_bot_token`. On pve1: `/etc/pve/priv/notifications.cfg`. On pbs1: `/etc/proxmox-backup/notifications-priv.cfg`, root only. The pbs1 copy sits on the VM's system disk, on the workstation's unencrypted volume (X23). The chat id is an identifier, not a secret: `private/ansible/inventory/group_vars/all/notify.yaml` | The native notification systems of pve1 and pbs1 (webhook target `telegram`) | Yearly. On exposure, and when the laptop is lost. [R8](#r8-replace-the-telegram-bot-token) | Sending messages as the bot and reading what is sent to it. False alerts are possible. No access to the lab |
| healthchecks.io ping URL | 2026-10-06 (owner). To be regenerated: it appeared once in a session transcript | `private/ansible/inventory/host_vars/pve1/secrets.sops.yaml`, key `pve_backup_ping_url`. On pve1: `/etc/homelab/backup.secret`, root only | `pbs-host-backup`, after a successful backup only | On exposure. [R9](#r9-replace-the-healthchecksio-ping-url) | Someone can report a backup as done, which hides a failed one. Nothing else |

## 7. External accounts

Logins, second factors and recovery codes are held by the owner. None of them is in either repository. Where each account's second factor and recovery codes are kept is not recorded yet (see [Open](#open)).

| Account | Used for | Rotation | If it leaks |
|---|---|---|---|
| Password manager | Holds the recovery keys and every break-glass password in this register | Master password on exposure | Everything in this register that names the password manager |
| GitHub | Owns the public and the private repository, the ruleset, and CI | Password on exposure. Hardware keys are planned (backlog B8) | The private repository can be read (ciphertext and identifiers) and both can be changed. Without an age key no secret is readable |
| Cloudflare | Holds the lab's DNS zone. No API token exists yet | Password on exposure | DNS of the zone can be changed |
| Backblaze | Owns the state bucket and its application key | Password on exposure. The application key: [R7](#r7-replace-the-b2-application-key) | Buckets and keys can be created and deleted. State objects are ciphertext |
| healthchecks.io | Owns the dead-man's switch of the nightly backup | Password on exposure. The ping URL: [R9](#r9-replace-the-healthchecksio-ping-url) | The check can be paused or deleted, which silences the alert for a missing backup |
| Telegram | Owns the bot (BotFather) and receives the notifications | The bot token: [R8](#r8-replace-the-telegram-bot-token) | The bot can be taken over or deleted |

## 8. Derived copies

These are not secrets of their own. They carry a secret from the tables above and must not outlive their use.

| Copy | Carries | Removed by |
|---|---|---|
| `F:\homelab\iso\pve1-auto.iso` (`just pve-media iso`) | Hash of the pve1 root password | By hand, after the stick is written. The script prints this reminder |
| A stick written by hand from that image (rebuild of a dead hypervisor) | The same hash | By hand, after the install. Only the stick whose serial is recorded in `private/proxmox/pve1.yaml` is blanked by `just pve-apply` |
| The install stick in Node 1 (`just pve-media prepare`) | The same hash | The first task of `just pve-apply` overwrites the image and removes its boot entry |
| `F:\homelab\iso\pbs1-auto.iso` (`just pbs-media`) | Hash of the pbs1 root password | `pbs-vm.ps1 -Eject` |
| `private/opentofu/state-copies/<root>.state.json` | The encrypted state, exactly as the bucket holds it | Kept on purpose. The private repository's guard refuses a copy that is not ciphertext |

## Procedures

### R1. Replace an SSH key

Use it for the lab key, or for the recovery key after it was used.

Needed: a session open with a key that the hosts accept today, and the management window open for pbs1.

`just openwrt-ssh-keys`, `just pve-apply` and `just pbs-apply` all refuse a key list with fewer than two keys, or without a key that the agent holds. The key in use therefore stays in the list until the new key is proven. That takes two passes.

1. Create the new key pair beside the current one, with a passphrase:

   ```
   ssh-keygen -t ed25519 -f ~/.ssh/homelab_ed25519.new
   ```

2. Add the new public key to the list `openwrt_ssh_authorized_keys` in `private/ansible/inventory/group_vars/all/ssh.yaml`. Keep the other keys.
3. Install the list on all five hosts:

   ```
   just openwrt-ssh-keys
   just pve-apply
   just pbs-apply
   ```

   The first recipe reports, for each of the three devices, the number of authorised keys and "updated and verified by a fresh login".
4. Switch the workstation to the new key:

   ```
   just session-end
   mv ~/.ssh/homelab_ed25519 ~/.ssh/homelab_ed25519.old
   mv ~/.ssh/homelab_ed25519.new ~/.ssh/homelab_ed25519
   mv ~/.ssh/homelab_ed25519.new.pub ~/.ssh/homelab_ed25519.pub
   just session-start
   ```

5. Remove the old public key from the list. Two keys remain at least: the new lab key and the recovery key.
6. Run the three recipes of step 3 again.
7. Check, without the agent, that the old key is refused. Expect `Permission denied` from each host:

   ```
   ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/homelab_ed25519.old ops@10.0.10.10 true
   ```

   Repeat for `root@192.168.1.53`, `root@10.0.10.2`, `root@10.0.10.3`, and for pbs1 with the options shown under "How to read it".
8. Delete `~/.ssh/homelab_ed25519.old`. Commit and push the private repository. Close the management window.

Recovery key: the same steps, with the new private half stored in the password manager only and never left on the workstation.

Laptop lost: the old private key is gone, so the recovery key is the key in use for the first pass, and the lost key is removed from the list in step 2 already. How a session is opened from the recovery keys on a replacement workstation is in [restore-workstation.md](../runbooks/restore-workstation.md), section 3. That sequence has not been rehearsed (see [Open](#open)).

### R2. Change a Wi-Fi key

Work from the dock port, not over the wireless network whose key changes: the apply must be able to log in again, or the device reverts.

1. Store the new key in the file that holds the variable:

   ```
   just secret-set <file> <variable>
   ```

2. See what will change, with real values:

   ```
   just openwrt-check openwrt
   ```

3. Apply to the access points first, then to the router. Each device reverts by itself unless the change verifies:

   ```
   just openwrt-apply openwrt_aps
   just openwrt-apply openwrt_routers
   ```

4. Reconnect the clients with the new key. Commit and push the private repository.

### R3. Change a root password

For pve1 the file is `private/proxmox/pve1.sops.yaml` and the key `pve_root_password`. For pbs1: `private/proxmox/pbs1.sops.yaml` and `pbs_root_password`, with the management window open.

1. Generate the new password in the password manager.
2. Store it:

   ```
   just secret-set private/proxmox/pve1.sops.yaml pve_root_password
   ```

3. Log in to the host as `ops` and set it:

   ```
   sudo passwd root
   ```

4. Commit and push the private repository.

No play sets a root password on a running host. The stored value is what the next install image embeds, so steps 2 and 3 must use the same value.

### R4. Change the administrator password

1. Generate the new password in the password manager.
2. Store it:

   ```
   just secret-set private/ansible/inventory/host_vars/pve1/secrets.sops.yaml pve_admin_password
   ```

3. On pve1, set it. The command asks twice:

   ```
   sudo pveum passwd octenite-admin@pve
   ```

4. Commit and push the private repository.

`just pve-apply` does not do this: it sets the password only when the account has none.

### R5. Replace a hypervisor API token

1. On pve1, remove the token. Example for the OpenTofu token:

   ```
   sudo pveum user token remove terraform@pve tofu
   ```

2. Issue it again. The secret goes straight into `private/proxmox/tokens.sops.yaml` and is never displayed:

   ```
   just pve-tokens
   ```

   Expect the report "Issued ...; secrets stored in private/proxmox/tokens.sops.yaml".
3. Commit and push the private repository.
4. Update the consumer of that token, once one exists.

### R6. Replace the backup token

1. Open the management window.
2. On pbs1, remove the token:

   ```
   sudo proxmox-backup-manager user delete-token pve1@pbs backup
   ```

3. Run the init play:

   ```
   just pve-backup-init
   ```

   It issues a new token, stores it in the private repository, writes it into the storage entry and into `/etc/homelab/backup.secret`, and checks that the storage is active. Expect "Backup path ready and checked" and "A new token was issued and recorded". No manual `pvesm` step is needed.
4. Commit and push the private repository. Close the management window.

### The backup encryption key is not rotated

`just pve-backup-init` never generates a second key and never overwrites a recorded one. On a rebuilt hypervisor it creates the storage entry with the recorded key. If the key on the host differs from the recorded key, the play stops and changes nothing.

A rotation would mean all of this, and none of it is built or rehearsed as a routine:

- Every existing backup stays readable with the old key only. The old key must be kept until those backups are pruned, or the backups are deleted.
- The storage entry is removed on pve1, the recorded entry is removed from `private/proxmox/backup-keys.sops.yaml` by hand, and `just pve-backup-init` then creates a new entry with a new key and records it.
- A full new backup set follows, and the new key goes to the password manager.

It was done once, on 2026-10-06, while the datastore held two test snapshots (`docs/phases/phase-3.md`, incident).

### R7. Replace the B2 application key

1. In the Backblaze console, create a new application key that is limited to the state bucket.
2. Store both halves:

   ```
   just secret-set private/opentofu/b2.sops.yaml b2_key_id
   just secret-set private/opentofu/b2.sops.yaml b2_application_key
   ```

3. Prove it, once the backend is initialised. Expect a plan without an authentication error:

   ```
   just tofu pve plan
   ```

4. Delete the old key in the console. Commit and push the private repository.

### R8. Replace the Telegram bot token

1. In Telegram, ask BotFather to revoke the token of the bot. It answers with a new one.
2. Store it:

   ```
   just secret-set private/ansible/inventory/group_vars/all/notify.sops.yaml telegram_bot_token
   ```

3. Deploy it to both hosts. The second recipe needs the management window:

   ```
   just pve-apply
   just pbs-apply
   ```

4. Send a test notification from the web interface of each host and confirm that it arrives.
5. Commit and push the private repository. Close the management window.

### R9. Replace the healthchecks.io ping URL

1. In healthchecks.io, regenerate the ping URL of the check.
2. Store it:

   ```
   just secret-set private/ansible/inventory/host_vars/pve1/secrets.sops.yaml pve_backup_ping_url
   ```

3. Deploy it. The play writes it to `/etc/homelab/backup.secret`:

   ```
   just pve-apply
   ```

4. After the next backup at 02:30, the check in healthchecks.io must show a new ping.
5. Commit and push the private repository.

## Open

| # | Item | Who | Closes when |
|---|---|---|---|
| O1 | The two runbooks for a lost or stolen workstation are written and not rehearsed: [restore-workstation.md](../runbooks/restore-workstation.md), whose section 3 opens a session from the recovery keys on a replacement workstation, and [operator-key-compromised.md](../runbooks/operator-key-compromised.md), which [bootstrap-keys.md](../runbooks/bootstrap-keys.md) names for a stolen laptop | Engineer | The first was rehearsed (backlog B30) |
| O2 | Password-manager copies not confirmed: the pbs1 root password and the OpenWrt root passwords. Confirmed by the owner on 2026-10-06: the backup encryption key (entry replaced after the rotation) and the TOTP recovery keys of both hypervisor accounts | Owner | The owner confirms each remaining entry |
| O3 | The healthchecks.io ping URL appeared once in a session transcript | Owner, then engineer | R9 done |
| O4 | `root@pam` on pbs1 has no second factor | Owner | Backlog B24 |
| O5 | No rotation path for the state passphrase | Engineer | Backlog B29 |
| O6 | Where the second factor and the recovery codes of each external account are kept is not recorded | Owner | The owner states it per account and section 7 is updated |
| O7 | The scope of the B2 application key (state bucket only) is not verified | Engineer | Checked when the backend is initialised (`docs/phases/phase-3.md`, G2) |

Not yet created, added when they exist: API tokens for Cloudflare, the per-writer B2 keys and repository passwords of the off-site backups, the OpenBao seal key, the Talos secrets bundle.
