# Runbook: the operator's SSH key or age key may be in other hands

Use this when the workstation was lost or stolen, when a passphrase may be known to someone else, or when a key file may have been copied.

Status: not drilled. The steps follow the roles, the session script and `private/.sops.yaml` as they are today. Record the first use or drill in the phase record.

## What the keys open

| Key | File on the workstation | Opens |
|---|---|---|
| Operator SSH key | `~/.ssh/homelab_ed25519`, passphrase-protected | Root on the router and both access points. The account `ops`, with sudo, on the hypervisor and the backup server |
| Operator age key | `~/.config/sops/age/operator.age`, passphrase-encrypted | Every SOPS file in the private repository |

Both files are useless without their passphrases. An open session holds both keys decrypted in memory until it is closed, the machine powers off, or 12 hours have passed.

The lab admits SSH only from the workstation's two addresses (192.168.1.196, 192.168.1.197), so a stolen SSH key also needs a place in the home network. A stolen age key needs nothing but a copy of the private repository, and the workstation carries one. That is why the age key comes first.

Two cases:

| | Case A: keys still in hand | Case B: workstation gone |
|---|---|---|
| Example | A passphrase was typed where others could see it | Laptop stolen |
| Decrypt with | The current operator age key, in a session | The recovery age key |
| Log in to hosts with | The current operator SSH key | The recovery SSH key |
| Also readable to the other party, without any passphrase | Nothing | The GitHub CLI token, and the backup server VM's system disk with the Telegram bot token (X23) |

Case B overlaps with [restore-workstation.md](restore-workstation.md), section 3, which creates both new keys and rolls the SSH key out while a workstation is rebuilt. If that section has been done, do here: step 1, steps 2.5 to 2.7 as in case A, with the session's key (they then only replace the data keys), step 2.9, step 3.11 and step 4.

## Before starting

- A workstation that holds one of the two addresses, with the repository and its tools (`just setup`). Building a replacement workstation: [restore-workstation.md](restore-workstation.md).
- The private repository on `main` and in step with GitHub: `just private-status`.
- Case B: the password manager entries of the recovery age key and the recovery SSH key.
- Work in WSL, in the repository's top directory.

## Order of actions

| Step | What | Why in this order |
|---|---|---|
| 1 | Contain | Minutes count for what needs no passphrase |
| 2 | New age key, private repository re-encrypted | Every secret rotated later must be unreadable to the old key |
| 3 | New SSH key on all five hosts | Closes the old key's logins |
| 4 | Rotate what the old key could read | Re-encryption does not take back what was already readable |

## 1. Contain

1. Case A: close the session.

   ```sh
   just session-end
   ```

2. Case B: revoke the GitHub CLI token in the GitHub account settings. It was in a readable file on the laptop. Check both repositories for pushes that are not yours.
3. Write down the time. Step 4 covers every secret that existed before it.

## 2. New age key and re-encryption

Case B: no session can open until both new key files exist. Do step 2.2 and step 3.1 first; `just session-start` needs both files.

1. Case A: open a session with the current keys.

   ```sh
   just session-start
   ```

2. Create the new operator key beside the old one. `age-keygen` prints a line `Public key: age1...`: copy it. `age -p` asks twice for a new passphrase. Details: [bootstrap-keys.md](bootstrap-keys.md), section 1.

   ```sh
   age-keygen | age -p -a -o ~/.config/sops/age/operator.age.new
   chmod 600 ~/.config/sops/age/operator.age.new
   ```

   Case B: no old file exists. Write to `~/.config/sops/age/operator.age` directly.

3. Find the recipient to replace. `private/.sops.yaml` has one rule with two recipients: operator and recovery.

   Case A: this prints the current operator's public key.

   ```sh
   age-keygen -y /dev/shm/homelab-session/age.key
   ```

   Case B: the recovery public key is in the password manager entry. The other recipient is the operator's.

4. Edit `private/.sops.yaml`: replace the old operator recipient with the new public key. Leave the recovery recipient.

5. Give `sops` a key that can still decrypt.

   Case A:

   ```sh
   export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
   ```

   Case B: the recovery key is used only offline and is never stored ([bootstrap-keys.md](bootstrap-keys.md), section 2). Disconnect the machine from every network, or use a live-USB environment with a clone of the private repository. Type the key into this one shell, and close the shell after step 2.7:

   ```sh
   read -rs SOPS_AGE_KEY && export SOPS_AGE_KEY
   ```

6. Re-encrypt every SOPS file. `rotate` replaces a file's data key, so a data key taken with the old key opens no later version. `updatekeys` then wraps the new data key for the recipients in `.sops.yaml`. The order matters: after `updatekeys` the old key can no longer open the file.

   ```sh
   cd private
   git ls-files | grep -E '[^/]\.sops\.(ya?ml|json|env|ini)$' | while IFS= read -r f; do
     sops rotate -i "$f" </dev/null && sops updatekeys -y "$f" </dev/null || { echo "FAILED: $f"; break; }
   done
   ```

   No line starting with `FAILED` may appear.

7. Run the private repository's guard.

   ```sh
   sh scripts/check-encrypted.sh
   cd ..
   ```

   Expect `check: all SOPS files are encrypted and no key material is present`.

8. Put the new key in place and prove it.

   Case A:

   ```sh
   just session-end
   mv ~/.config/sops/age/operator.age.new ~/.config/sops/age/operator.age
   just session-start
   just reveal private/selftest/selftest.sops.yaml
   ```

   Case B: the offline shell is closed and the network is back. The new key file is already in place.

   ```sh
   just session-start
   just reveal private/selftest/selftest.sops.yaml
   ```

   `just session-start` asks for the new age passphrase. The last command must print two lines, `purpose:` and `canary:`.

9. Commit and push the private repository.

   ```sh
   git -C private add -A
   git -C private commit -m "Re-encrypt to a new operator key"
   git -C private push
   just private-status
   ```

Every copy of the private repository made before this commit stays readable with the old key. Step 4 deals with that.

## 3. New SSH key on all five hosts

Where the public keys live. All five hosts read one list: `openwrt_ssh_authorized_keys` in `private/ansible/inventory/group_vars/all/ssh.yaml`.

| Host | Address | Account | Replaced by |
|---|---|---|---|
| Router | 192.168.1.53 | root | `just openwrt-ssh-keys` |
| Access point 1 | 10.0.10.2 | root | `just openwrt-ssh-keys` |
| Access point 2 | 10.0.10.3 | root | `just openwrt-ssh-keys` |
| Hypervisor | 10.0.10.10 | `ops` | `just pve-apply` |
| Backup server | through the workstation, port 2222, management window open | `ops` | `just pbs-apply` |

How the roles replace keys:

- Each role writes the whole list and removes every key that is not in it.
- The guard: the list must hold at least two keys, and one of them must be loaded in the session's agent. Otherwise the play stops with "The key list must hold at least two keys, one of them loaded in the agent" and leaves the authorised keys as they were.
- The router and the access points also restore their previous key file after two minutes unless a fresh login succeeds.
- Root has no SSH path on the hypervisor and the backup server, so there is no root key to replace there.

So during the change the agent must hold two keys: one that the hosts still accept, and the new one.

1. Create the new key pair. Choose a new passphrase.

   ```sh
   ssh-keygen -t ed25519 -C homelab-ops -f ~/.ssh/homelab_ed25519.new
   ```

   Case B: no old file exists. Write to `~/.ssh/homelab_ed25519` directly. The session of step 2.8 loads it.

2. Load the second key into the session's agent.

   Case A, the new key:

   ```sh
   export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"
   ssh-add -t 12h ~/.ssh/homelab_ed25519.new
   ```

   Case B, the recovery key from the password manager, held in memory only:

   ```sh
   export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"
   (umask 077; cat > /dev/shm/homelab-recovery-key)     # paste the private key, then Ctrl+D
   ssh-add -t 2h /dev/shm/homelab-recovery-key
   rm /dev/shm/homelab-recovery-key
   ```

   `ssh-add -l` now lists two keys.

3. Edit `private/ansible/inventory/group_vars/all/ssh.yaml`: replace the line of the key named `homelab-ops` with the content of the new `.pub` file. Keep the shape of the line: two spaces, a dash, the whole key in double quotes. The install-media builders read the file by that shape. Leave the `homelab-recovery` line.

4. Router and access points, one at a time.

   ```sh
   just openwrt-ssh-keys
   ```

   Each device reports its two authorised keys by name and `updated and verified by a fresh login`.

5. Hypervisor.

   ```sh
   just pve-apply
   ```

6. Backup server. Case B: the VM went with the laptop. Build it again instead ([pbs.md](../components/pbs.md), Deployment); the installer takes its keys from the same list.

   Case A, in an elevated PowerShell, with the VM running:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage
   ```

   ```sh
   just pbs-apply
   ```

7. Case A: put the new key in place and open a session that holds only it.

   ```sh
   just session-end
   mv ~/.ssh/homelab_ed25519 ~/.ssh/homelab_ed25519.old
   mv ~/.ssh/homelab_ed25519.new ~/.ssh/homelab_ed25519
   mv ~/.ssh/homelab_ed25519.new.pub ~/.ssh/homelab_ed25519.pub
   just session-start
   ```

   Case B: `just session-end`, then `just session-start`, so the recovery key leaves the agent.

8. Prove that the new key alone opens every host. No run may fail.

   ```sh
   just openwrt-ssh-keys
   just pve-apply
   just pbs-apply
   ```

   The first reports `already as in the inventory` for each device. The other two report `changed=0`.

9. Case A: prove that the old key is refused, then delete it. Each command asks for the old passphrase and must end with `Permission denied`.

   ```sh
   ssh -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/homelab_ed25519.old ops@10.0.10.10 true
   ssh -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/homelab_ed25519.old root@192.168.1.53 true
   rm ~/.ssh/homelab_ed25519.old
   ```

10. Close the management window with a plain run of `pbs-vm.ps1`. Commit and push the private repository as in step 2.9.

11. Delete any install image left in `F:\homelab\iso`. It embeds the old key list.

Case B: the recovery SSH key has now been used. The register's rule for it is rotation on use: make a new recovery pair as the register describes and repeat steps 3 to 8 with its line.

## 4. Rotate what the old key could read

[secrets-register.md](../security/secrets-register.md) lists every secret, where it lives and how it rotates. It is authoritative for each procedure. Rotate every row whose secret is in the private repository. Case B: also every row that names the workstation or the backup server VM.

Work in this order:

| Order | Rows | Why here | Recipes involved |
|---|---|---|---|
| 1 | Backblaze B2 application key, Telegram bot token, healthchecks.io ping URL | Usable from anywhere on the internet | `just secret-set`, then `just pve-apply` and `just pbs-apply` |
| 2 | Wi-Fi keys | A way into the home network | `just openwrt-apply <target>` for the router and each access point |
| 3 | Proxmox API tokens, backup server token | Usable from inside the home network | `just pve-tokens`, `just pve-backup-init` |
| 4 | Passwords: `root@pam` on both Proxmox hosts, the hypervisor's administrator account | Console and web logins, behind a second factor on the hypervisor | By hand, as the register says |
| 5 | Backup encryption key, OpenTofu state passphrase | They protect data at rest. No recipe rotates them: `just pve-backup-init` never replaces a recorded key | Decide with the owner, as the register says |

The router configuration backups in the private repository contain Wi-Fi keys and password hashes. They cannot be rotated. Take a new backup set after the Wi-Fi keys have changed.

## How to know it worked

- `just reveal private/selftest/selftest.sops.yaml` prints its two lines in a session opened with the new passphrases.
- `sh scripts/check-encrypted.sh` in `private/` passes, and `just private-status` reports the private repository on `main`, clean and in step with GitHub.
- Step 3.8 passed with a session that holds only the new SSH key. Case A: step 3.9 showed `Permission denied` twice.
- Every register row touched in step 4 carries a new date.
- The event, its cause and the time from step 1.3 are in the phase record.
