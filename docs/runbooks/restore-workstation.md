# Runbook: rebuild the workstation side

Use this when the workstation (Node 2) was replaced or reinstalled, when its WSL environment was lost, or when the backup server VM `pbs1` or one of its disks has to be rebuilt. The workstation holds the tools, the operator's keys, the working clone of both repositories and the backup server VM with its datastore.

For the hypervisor, use [restore-pve-host.md](restore-pve-host.md). When both machines are gone, follow the order in [DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md), scenario 3.

Status: **not rehearsed.** The VM was built once with these scripts on 2026-10-06. No rebuild of it, and no rebuild of the workstation, has been run.

## Which sections apply

| Situation | Sections |
|---|---|
| New machine, or Windows installed again | 1 to 8 |
| WSL lost; Windows and the VM intact | 2 and 3 |
| Only the VM, or one of its disks, is damaged | 5 to 8 |

## Before starting

| Needed | Where from |
|---|---|
| The recovery age key, and the recovery SSH key with its passphrase (only when the WSL home directory was lost) | Password manager |
| A GitHub login that can read the private repository | The owner |
| Administrator rights on Windows | Every run of `pbs-vm.ps1` needs an elevated PowerShell |
| The hypervisor running at 10.0.10.10 | The backup server's install image is built on it |

## 1. Machine and network

1. Install Windows 11, enable Hyper-V, install WSL2 with Debian.
2. Provide a volume with the drive letter F:. `scripts\node2\pbs-vm.ps1` keeps the VM under `F:\homelab\pbs1` and install images under `F:\homelab\iso`. The datastore file is 128 GiB, fixed; the system disk grows to 32 GiB.
3. Cable the wired adapter to router port lan4 and give it the static address 192.168.1.196/24, gateway and DNS 192.168.1.53. The router, the access points and the hypervisor admit the workstation by address: 192.168.1.196 and 192.168.1.197, nothing else.
4. Plug in the USB 2.5 GbE adapter and cable it to Node 1's 2.5 GbE port. That is the direct link for backups.

The router's two address reservations are still bound to the old machine's adapters. After section 3, when a session works:

5. Put the new adapters' hardware addresses into `openwrt_workstation_mac` (wired, 192.168.1.196) and `openwrt_workstation_wifi_mac` (Wi-Fi, 192.168.1.197) in `private/ansible/inventory/host_vars/router-m30/identifiers.yaml`. They belong in the private repository only.
6. Apply and switch the adapter back to DHCP:

   ```sh
   just openwrt-check openwrt_routers
   just openwrt-apply openwrt_routers
   ```

7. Commit and push the private repository:

   ```sh
   git -C private add ansible/inventory/host_vars/router-m30/identifiers.yaml
   git -C private commit -m "Workstation adapters after the rebuild"
   git -C private push
   ```

## 2. Tools and repositories

1. In WSL, install mise and activate it in `~/.bashrc`. The two lines are in [bootstrap-keys.md](bootstrap-keys.md), section 0. Open a new terminal afterwards.
2. Clone the public repository from GitHub onto a Windows drive. The present layout is `D:\Dev\homelab-infra`, which is `/mnt/d/Dev/homelab-infra` in WSL. Both sides need the files: `just` runs in WSL, `pbs-vm.ps1` in Windows PowerShell.
3. Install the pinned tools, the Git hooks and the private repository:

   ```sh
   cd /mnt/d/Dev/homelab-infra
   mise trust
   mise install
   just setup
   ```

   `just setup` checks out the submodule `private/` and switches it to `main`. Git must be able to log in to GitHub for it.

4. Install the pinned Ansible collections. They are not in Git, and `just setup` does not fetch them:

   ```sh
   just ansible-deps
   ```

5. Check the private repository:

   ```sh
   just private-status
   ```

   Expected: `private/ is on main, clean and in step with GitHub`.

6. Enable the private repository's own commit checks, once:

   ```sh
   cd private && mise trust && mise install && pre-commit install && cd ..
   ```

## 3. Keys

If `~/.config/sops/age/operator.age` and `~/.ssh/homelab_ed25519` still exist in WSL, skip this section.

Otherwise both keys are gone. They existed only here. New ones are created, and the recovery keys from the password manager bridge the gap. No recipe covers this, and the sequence has not been rehearsed.

1. Create a new operator age key: [bootstrap-keys.md](bootstrap-keys.md), section 1. Keep its public key.
2. In `private/.sops.yaml`, replace the old operator recipient with the new public key. Keep the recovery recipient. The recovery key's public key is in its password manager entry; the other recipient is the old operator's.
3. Re-encrypt every SOPS file to the new recipients. Only the recovery age key can still decrypt them. This is the one moment that key is typed on the workstation: unplug the network first, and unset the variable in the same step. The list leaves out `.sops.yaml` itself, which is plain text.

   ```sh
   cd private
   read -rs SOPS_AGE_KEY && export SOPS_AGE_KEY     # the secret-key line of the recovery age key
   git ls-files | grep -E '[^/]\.sops\.(ya?ml|json|env|ini)$' | while IFS= read -r f; do
     sops updatekeys -y "$f" </dev/null || { echo "FAILED: $f"; break; }
   done
   unset SOPS_AGE_KEY
   cd ..
   ```

   No line starting with `FAILED` may appear.

4. Create a new lab SSH key at the path `just session-start` loads. Give it a passphrase:

   ```sh
   ssh-keygen -t ed25519 -C homelab-ops -f ~/.ssh/homelab_ed25519
   ```

5. In `private/ansible/inventory/group_vars/all/ssh.yaml`, replace the lost lab key's line (`homelab-ops`) in `openwrt_ssh_authorized_keys` with the content of `~/.ssh/homelab_ed25519.pub`. Keep the shape of the line: two spaces, a dash, the whole key in double quotes. `just pbs-media` and `just pve-media` read the file by that shape. Keep the recovery key's line (`homelab-recovery`): the plays refuse a list with fewer than two keys.
6. Reconnect the network. Commit and push the private repository:

   ```sh
   git -C private add -A
   git -C private commit -m "New operator key and lab SSH key after the workstation rebuild"
   git -C private push
   ```

7. Open a session with the new keys:

   ```sh
   just session-start
   ```

8. No device knows the new SSH key yet. Load the recovery SSH key into the session's agent for this rollout, without writing it to a disk. Paste the private key, press Ctrl+D, then type its passphrase:

   ```sh
   SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock" ssh-add -t 1h -
   ```

9. Install the new key list on the network devices and the hypervisor:

   ```sh
   just openwrt-ssh-keys
   just pve-apply
   ```

   The backup server VM depends on its state:

   | VM | When it gets the new list |
   |---|---|
   | Intact and running (only WSL was lost) | Now, while the agent still holds the recovery key: open the management window (section 6), run `just pbs-apply`, close the window |
   | Reinstalled in section 5 (5B, 5C) | From its install image. `just pbs-apply` keeps it current |
   | System disk kept, definition rebuilt (5A) | In 5A, step 4. It still holds the old list |

10. Close the session and open it again. The agent then holds the new key only:

    ```sh
    just session-end
    just session-start
    just openwrt-check openwrt
    ```

    Expected: the check reaches the router and both access points.

The recovery SSH key has now been used. The [secrets register](../security/secrets-register.md) rotates it on use.

If the old machine was stolen and not merely broken: its disks were not encrypted (exception X23), so the old key files are protected by their passphrases only. Steps 2 to 9 remove both old keys from every recipient list and every host. They do not rotate the secrets themselves: continue with [operator-key-compromised.md](operator-key-compromised.md), case B, which says what is left to do after this section. That runbook has not been drilled.

## 4. WSL memory cap and the direct-link adapter

The memory budget on the workstation is 4 GiB fixed for the VM and 5 GB for WSL.

1. Create `%USERPROFILE%\.wslconfig` if it does not exist, with these two lines:

   ```
   [wsl2]
   memory=5GB
   ```

   `pbs-vm.ps1` keeps an existing `memory=` line at 5GB on every run. It does not create the file or the line. Without the file it prints `note:   .wslconfig absent; WSL cap not set`, without the line `note:   .wslconfig has no memory line; WSL cap not set`.

2. Apply it from PowerShell. This stops WSL and ends an open session; run `just session-start` again afterwards:

   ```powershell
   wsl --shutdown
   ```

3. With the USB 2.5 GbE adapter plugged in, switch its power management off, in an elevated PowerShell in the repository:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\workstation.ps1
   ```

## 5. Backup server VM

Every `pbs-vm.ps1` command below runs in an elevated PowerShell, in the repository:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 <switches>
```

The script is idempotent and prints only what it changed. Every run also converges the two switches, the NAT, the port ACLs, the firewall rules that fence the VM, the port forward on 8007 and the WSL cap.

Look at `F:\homelab\pbs1\disks` and choose:

| `system.vhdx` | `datastore.vhdx` | Path | The backups |
|---|---|---|---|
| Intact | Intact | 5A | Kept |
| Missing or damaged | Intact | 5B | Kept |
| Any | Missing or damaged | 5C | **Gone** |

`-WipeDatastore` deletes every backup. It is never part of 5A or 5B.

### 5A. Both disk files intact

Windows was reinstalled and the VM's definition is gone, but F: survived.

1. Run the script without switches. Expected: `change: vm pbs1 (generation 1, existing system disk)` and `change: datastore disk attached (SCSI)`.
2. Start the VM:

   ```powershell
   Start-VM pbs1
   ```

3. Open the management window (section 6). Section 7 needs it:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

4. Only if section 3 created new keys: the VM still authorises the old lab key and the recovery key, not the new one. In WSL, load the recovery SSH key into the agent again (section 3, step 8), install the new list, then open a session that holds the new key only:

   ```sh
   just pbs-apply
   just session-end
   just session-start
   ```

5. Continue with section 7. The VM kept its host key, its certificate and its token, so `just pve-backup-init` has nothing to repair.

### 5B. System disk rebuilt, datastore kept

1. In WSL, build the install image. It is built on the hypervisor and copied to the F: drive:

   ```sh
   just pbs-media
   ```

   Expected: `image ready and verified: /mnt/f/homelab/iso/pbs1-auto.iso`.

2. If the VM is running, stop it. Add `-TurnOff` only if the system no longer shuts down:

   ```powershell
   Stop-VM pbs1
   ```

3. Replace the system disk with an empty one and start the install:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -WipeSystem -Yes 'delete pbs1 system' -Iso F:\homelab\iso\pbs1-auto.iso
   ```

   Expected: `change: install medium attached` and `change: vm started; an empty system disk falls through to the install medium`. The script detaches the datastore disk for the install, so the installer sees one disk only.

   The empty disk matters. The system disk always boots first, so a disk that still boots never enters the installer. `-Recreate` rebuilds only the VM's definition and keeps both disks; it does not reinstall the system.

4. Watch the VM's console in Hyper-V Manager. The install asks nothing and reboots into the installed system. Wait for its login prompt.
5. Detach the medium. The script deletes the image, which embeds a password hash, and attaches the datastore disk again:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Eject
   ```

   Expected: `change: install medium detached` and `change: datastore disk attached (SCSI)`.

6. Open the management window (section 6):

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

7. In WSL, forget the old host key. The inventory keeps it under the alias `pbs1`:

   ```sh
   ssh-keygen -R pbs1
   ```

8. First contact, as root, once. Ansible shows the new host key and asks; answer `yes`:

   ```sh
   just pbs-bootstrap
   ```

9. Configure the VM:

   ```sh
   just pbs-apply
   ```

   The role finds the kept disk by its label, mounts it and registers the datastore again with its content. It never creates a datastore over existing chunks. A further run shows `changed=0`.

10. Continue with section 7.

### 5C. Datastore lost

What is gone: every host-configuration snapshot. There is no off-site copy. The encryption key does not change; `just pve-backup-init` never generates a new one while a key is recorded. The live hypervisor still holds the data, and the first new backup in section 7 restores the protection.

**New machine, or the system disk is rebuilt too.**

1. If a damaged `datastore.vhdx` is still there, replace it with an empty one, with the VM off:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -WipeDatastore -Yes 'delete pbs1 datastore'
   ```

   On a new machine the script creates the file by itself.

2. Follow 5B from step 1. On a new machine, where neither the VM nor `system.vhdx` exists, step 3 needs no `-WipeSystem`:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Iso F:\homelab\iso\pbs1-auto.iso
   ```

   In step 9 the role finds an empty disk: it partitions and formats it, mounts it and creates an empty datastore. No flag is needed on a fresh system.

**The system disk is kept; only the datastore disk is replaced.**

1. Stop the VM, replace the disk, start the VM, open the management window:

   ```powershell
   Stop-VM pbs1
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -WipeDatastore -Yes 'delete pbs1 datastore'
   Start-VM pbs1
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

2. The system still lists the old datastore, so a plain `just pbs-apply` stops with `The server lists the datastore pbs1, but /mnt/datastore/pbs1 holds no chunk store`. Confirm the loss with the recreate flag:

   ```sh
   just pbs-apply -e pbs_host_datastore_recreate=true
   ```

   The role forgets the old datastore, keeps its jobs and access entries, and creates an empty one.

3. Run the play once more without the flag. It must show `changed=0`:

   ```sh
   just pbs-apply
   ```

4. Continue with section 7.

## 6. The management window

WSL has no route to the VM. Ansible reaches it through a port forward on the Windows host, port 2222 to the VM's SSH port, which exists only while the window is open.

| State | Command | Effect |
|---|---|---|
| Open | `pbs-vm.ps1 -Manage` | Adds the forward on 2222 and the allow rule `homelab-pbs1-ssh-wsl`, from WSL's address range only. Prints `management window: OPEN` |
| Closed | `pbs-vm.ps1` without switches | Removes the forward and the rule. Prints `management window: closed.` |

It is opened by hand and closed by hand. Close it when the work is done. `just test-fences` prints which state is live.

These need the VM running and the window open: `just pbs-bootstrap`, `just pbs-apply`, `just pve-backup-init`, `PVE_BUILDER=pbs1 just pve-media ...`, and the backup-server part of `just test-fences`. The VM is started by hand: `Start-VM pbs1`.

## 7. Reconnect the hypervisor

The window is still open.

1. Repair the hypervisor's storage entry:

   ```sh
   just pve-backup-init
   ```

   After a reinstall of the VM the play issues a new token and writes it, together with the VM's new certificate fingerprint, into the existing entry. Expected: `Backup path ready and checked: storage pbs-node2 on pve1 is active through <address>`, and after a reinstall `A new token was issued and recorded: commit the private repository.`

2. If a token was issued, commit and push it:

   ```sh
   git -C private add proxmox/tokens.sops.yaml
   git -C private commit -m "New backup server token after the rebuild"
   git -C private push
   just private-status
   ```

3. Take a backup now and list the snapshots:

   ```sh
   export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"
   ssh ops@10.0.10.10 sudo systemctl start pbs-host-backup.service
   ssh ops@10.0.10.10 sudo pbs-host-restore list
   ```

   After 5A and 5B the earlier snapshots are listed with the new one. After 5C there is one.

## 8. Fence test

The script fences the VM on every run: block rules for everything from the direct link and from the VM, and for the two forwarded ports from every source but the admitted one. The deny test proves them from the hypervisor, the router, WSL and the VM.

1. With the window still open, so the VM is probed too:

   ```sh
   just test-fences
   ```

   Expected last line: `fences hold: <n> probes, all as expected`.

2. Close the window, in the elevated PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1
   ```

   Expected: `management window: closed.`

3. Run the test again:

   ```sh
   just test-fences
   ```

   Expected: `management window: closed`, a `SKIP` line for the backup server's probes, and `fences hold` at the end.

A single `FAIL` line, or `FENCES BROKEN` at the end, means the rebuild is not finished. On the present workstation a passing run is still open; see [phase-3.md](../phases/phase-3.md).

## How to know it worked

| Check | Expected |
|---|---|
| `just private-status` | On `main`, clean, in step with GitHub |
| `just session-status` | The age key is open with a deadline, and the agent holds a key |
| `just pbs-apply`, with the window open | `failed=0`, `changed=0` |
| `just pve-backup-init`, with the window open | `Backup path ready and checked`, no change |
| `pbs-host-restore list` on the hypervisor | A snapshot from today |
| `just test-fences`, window closed | `fences hold` |

Record the date, the path taken and the time in the drill log of [DISASTER-RECOVERY.md](../../DISASTER-RECOVERY.md).

## If something fails

| Symptom | Cause and action |
|---|---|
| `Run this in an elevated PowerShell.` | Start PowerShell as administrator |
| `Hyper-V PowerShell module not available.` | Enable Hyper-V in Windows, reboot, run again |
| `This needs the VM off: Stop-VM pbs1, then run again.` | `-Iso`, `-WipeSystem` and `-WipeDatastore` refuse a running VM |
| A destructive switch prints `Nothing was changed. To go ahead, repeat the command with:  -Yes '...'` | Intended. Read what it will delete, then repeat with the phrase |
| `note:   no direct-link adapter present` | The USB adapter is unplugged. Plug it in and run the script again. Until then backups use the fallback through port 8007 |
| The old system boots although `-Iso` was given | The system disk still boots, so the installer is never reached. Use `-WipeSystem` as in 5B, step 3 |
| `just pbs-media` cannot connect | The hypervisor does not answer: check the workstation's address (section 1) and the session |
| `just pbs-bootstrap` or `just pbs-apply`: the host is unreachable | The VM is off or the management window is closed (section 6) |
| `just pbs-bootstrap`: root is refused | The play already ran once and closed root login. Continue with `just pbs-apply` |
| `just pbs-apply`: the disk `holds something that is not the datastore` | Read the `lsblk` output in the message before anything else. Do not wipe a disk to get past this |
| `just pbs-apply`: `has a partition on which no filesystem is recognised` | If the disk held backups, do not format it; the message names the repair to try first |
| `just pve-backup-init`: `accepts no connection on port 8007` | Ansible reached the VM, but the hypervisor reaches port 8007 on no path. Check that the workstation holds 192.168.1.196 or 192.168.1.197, run `pbs-vm.ps1 -Manage` again (it restores the forward and its rules), look at `just test-fences`, then run the play again. The hypervisor was not changed |
