# Disaster recovery

Status: **partly tested.** This document covers the platform as built on 2026-10-07: the hypervisor, the backup server VM on the workstation, the router and the access points. No cluster exists yet. Two things are proven: the unattended reinstall of the running hypervisor, and the restore of its configuration backup into scratch directories. No rebuild after a loss, real or simulated, has been run. The drill log at the end says exactly what was done. A backup that has never been restored is not a backup.

The questions this document answers:

| If this is destroyed | Go to |
|---|---|
| The hypervisor (Node 1) | [Scenario 1](#scenario-1-the-hypervisor-is-destroyed) |
| The workstation (Node 2) | [Scenario 2](#scenario-2-the-workstation-is-destroyed) |
| Both at once | [Scenario 3](#scenario-3-both-are-destroyed) |
| The router or an access point | [docs/runbooks/restore-openwrt.md](docs/runbooks/restore-openwrt.md) |
| Only the backup server VM, workstation intact | [docs/runbooks/restore-workstation.md](docs/runbooks/restore-workstation.md), section 5 |

## Where each recovery prerequisite lives

| Prerequisite | Where it lives | Lost together with |
|---|---|---|
| Public repository: code, runbooks, this file | GitHub; the working clone on the workstation | Nothing short of GitHub and the workstation together |
| Private repository: SOPS-encrypted secrets, device identifiers, encrypted router exports | GitHub; the working clone on the workstation, mounted as the submodule `private/` | Commits not yet pushed are lost with the workstation. `just private-status` shows whether any exist |
| Recovery age key: decrypts every SOPS file | Password manager and two paper copies. Never on the workstation | Nothing in these scenarios |
| Recovery SSH key | Password manager, with its passphrase | Nothing in these scenarios |
| Operator age key and lab SSH key: daily use | The workstation only (WSL), each protected by a passphrase | The workstation. They are replaced, not recovered |
| Root password of the hypervisor, root password of the backup server, password of the hypervisor's administrator account | Private repository; password manager | Nothing in these scenarios |
| Second factor (TOTP) of the two hypervisor logins | The owner's authenticator app. The enrolment itself lives in the hypervisor's cluster database | The hypervisor. Enrolled again after every rebuild |
| Backup encryption key | The hypervisor; private repository (`private/proxmox/backup-keys.sops.yaml`); password manager | Nothing in these scenarios |
| Host-configuration backups | One copy: the datastore of the backup server VM, on the workstation's F: drive | The workstation. **There is no off-site copy** |
| Hypervisor API tokens, backup server token | Private repository (`private/proxmox/tokens.sops.yaml`); the hosts themselves | Re-issued by the plays after a rebuild |
| Router and access point configuration | Git; encrypted exports in the private repository under `openwrt/backups/` | Nothing in these scenarios |
| Install images | Not kept. Built on demand from Git and the private repository. The stock image names and checksums are pinned in `scripts/pve/build-install-media.sh` and `scripts/pbs/build-install-iso.sh` | Nothing |
| Account logins: GitHub, the object storage provider, the dead-man's-switch service, the notification bot | With the owner. Where each account's second factor and recovery codes are kept is not recorded yet ([secrets register](docs/security/secrets-register.md), Open) | Nothing in these scenarios |
| OpenTofu state | Encrypted in the object-storage bucket; the same ciphertext is kept in the private repository under `opentofu/state-copies/`. The passphrase and the bucket keys are in the private repository | Nothing in these scenarios |

Recovery always uses the private repository's `main` branch, not the commit the public repository pins. `just setup` switches to it. `just private-status` confirms it before a recovery starts.

## Scenario 1: the hypervisor is destroyed

The disk, or the whole machine, is gone. The workstation, the router and GitHub are intact.

| Lost | Survives, and where |
|---|---|
| The Proxmox system and its configuration | Git: the answer file and the Ansible roles rebuild it |
| The cluster database: users, tokens, TOTP enrolments, storage entries, guest configurations (none exist today) | The last nightly backup on the backup server VM. The backup runs at 02:30 and only succeeds when the VM is running then; the VM is started by hand, so the newest snapshot can be older than one day |
| Files under `/etc` and `/root` that are not in Git | The same backup |
| The thin pool with every guest disk (none exist today) | Nothing. From Phase 5 the guests are rebuilt or restored by the later phases |
| The host's copy of the backup encryption key | Private repository and password manager. The play puts it back |

Steps. The commands are in [docs/runbooks/restore-pve-host.md](docs/runbooks/restore-pve-host.md).

1. **Manual.** Provide the machine: the same one with a new disk, or a replacement. Firmware set to UEFI boot with virtualisation on. Cable the onboard port to router port lan1. If the disk or the board changed, edit the values listed in the runbook under "Replaced hardware".
2. On the workstation: open a session and check the private repository (`just session-start`, `just private-status`).
3. **Manual.** In an elevated PowerShell on the workstation: start the backup server VM and open the management window.
4. Build the install image on the backup server VM (runbook section 2B). **Manual:** write it to a USB stick, delete the image, boot Node 1 from the stick with the firmware's boot-menu key. The install itself asks nothing.
5. First contact and configuration: `just pve-bootstrap`, then `just pve-apply`. The first `just pve-apply` stops at its very end on purpose and says to run `just pve-backup-init`.
6. `just pve-tokens`, `just pve-backup-init`, then `just pve-apply` again, which must end clean. **Manual:** commit and push the private repository, because the tokens are new.
7. Restore what is not in Git into a scratch directory and copy back what is needed: [docs/runbooks/restore-host-config.md](docs/runbooks/restore-host-config.md).
8. **Manual.** Enrol TOTP again for both logins in the web interface. Then `just pve-apply` switches the requirement back on.
9. **Manual.** Close the management window. Record the run in the drill log below.

If no builder for the image is available, the runbook's section 2C is the fallback: the stock installer, answered by hand.

Manual steps that remain: hardware and firmware; starting the VM and opening the management window (elevated PowerShell); writing the stick and pressing the boot-menu key; accepting the new SSH host key; committing the private repository; TOTP enrolment; closing the window.

## Scenario 2: the workstation is destroyed

The workstation holds four things: the backup server VM, its datastore disk, WSL with the tools and keys, and the only clone of the private repository besides GitHub. The hypervisor keeps running; nothing in the lab depends on the workstation except backups and administration.

| Lost | Survives, and where |
|---|---|
| The backup server VM | Git: the VM script, the answer file and the Ansible role rebuild it |
| The datastore: every host-configuration backup | **Nothing, unless the F: drive survived.** There is no off-site copy. The live hypervisor still holds the data the backups were made from |
| WSL with the pinned tools | Git: `mise.toml` and `just setup` |
| The operator age key and the lab SSH key | Not recovered. New ones are created; the recovery age key and the recovery SSH key from the password manager bridge the gap |
| The clone of the private repository | GitHub. Unpushed commits are lost; a secret issued and not pushed is issued again |
| The administration path: only the workstation's two addresses are admitted by the lab's firewalls | The rules are by address, so a replacement machine on 192.168.1.196 is admitted |

Steps. The commands are in [docs/runbooks/restore-workstation.md](docs/runbooks/restore-workstation.md).

1. **Manual.** Provide the machine: Windows 11 with Hyper-V, WSL2 with Debian, a volume with the drive letter F:. Give its wired adapter the address 192.168.1.196 and cable it to router port lan4.
2. Tools and repositories: mise, the clone, `just setup`, `just ansible-deps`, `just private-status`.
3. **Manual.** Keys: a new operator age key and a new lab SSH key; both made recipients and authorised with the help of the recovery keys from the password manager. This step has no recipe and has never been rehearsed.
4. **Manual.** The WSL memory cap in `.wslconfig`.
5. The backup server VM: `just pbs-media`, then `scripts\node2\pbs-vm.ps1` in an elevated PowerShell, then `just pbs-bootstrap` and `just pbs-apply`. If the datastore file on F: survived it is attached again with its content. If not, the datastore starts empty.
6. `just pve-backup-init` gives the hypervisor's storage entry the new token and the new certificate fingerprint. **Manual:** commit and push the private repository.
7. Run one backup at once, so the hypervisor has a backup again.
8. **Manual.** Close the management window. `just test-fences` must end with `fences hold`.

Manual steps that remain: hardware, Windows, Hyper-V and WSL; the static address; fetching the recovery keys and typing passphrases; every run of `pbs-vm.ps1` (elevated PowerShell); `.wslconfig`; committing the private repository.

If the workstation was stolen and not merely broken: its disks are not encrypted (exception X23). The key files on it are protected by their passphrases only. Step 3 removes both keys from every recipient list and from every host. The secrets themselves are then rotated with [docs/runbooks/operator-key-compromised.md](docs/runbooks/operator-key-compromised.md), case B. That runbook has not been drilled (open).

## Scenario 3: both are destroyed

What this loses today, stated plainly:

- **Every host-configuration backup is gone.** The only copy was the datastore on the workstation. No off-site copy of the backups exists yet.
- Recovery is from Git plus the password manager: the two repositories on GitHub, the recovery age key and the recovery SSH key.
- State that was only in the hypervisor's cluster database or under `/root` is not recoverable. Today that is the two TOTP enrolments, which are enrolled again, and anything placed under `/root` by hand. No guests exist yet.
- The backup encryption key survives in the private repository and the password manager, but nothing is left for it to decrypt.
- No machine is left that can build an unattended install image. The hypervisor's image is built on the hypervisor or on the backup server VM, and the backup server's image is built on the hypervisor. The hypervisor is therefore installed with the stock installer by hand.

Steps, in this order because of that dependency:

1. Workstation, steps 1 to 4 of scenario 2: machine, tools, repositories, keys. [restore-workstation.md](docs/runbooks/restore-workstation.md), sections 1 to 4. In the key rollout leave out `just pve-apply`: the hypervisor does not exist yet and is installed with the new key in the next step.
2. Hypervisor by the manual fallback: [restore-pve-host.md](docs/runbooks/restore-pve-host.md), section 2C, then sections 3 and 4. `just pve-apply` stops at its end and asks for `just pve-backup-init`; that is expected, continue with the next step.
3. Backup server VM with an empty datastore: [restore-workstation.md](docs/runbooks/restore-workstation.md), section 5C. The image build needs the hypervisor from step 2.
4. `just pve-tokens`, `just pve-backup-init`, `just pve-apply` until clean: [restore-pve-host.md](docs/runbooks/restore-pve-host.md), section 5. The storage entry is created with the recorded encryption key, not a new one.
5. TOTP enrolment, one backup at once, `just test-fences`, management window closed.

Manual steps that remain: everything listed for scenarios 1 and 2, plus the whole interactive install of the hypervisor and placing the first SSH key for root by hand.

What closes the gap: the off-site copies of the backup design ([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 12), built with the later phases, and a way to build the hypervisor's install image on the workstation alone.

## Later phases: not built yet

Nothing below exists today. The design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 13; the recipes it names are not in the justfile yet.

| Step after the hypervisor is back | State |
|---|---|
| Talos VMs created by OpenTofu (`just tofu pve apply`) | The root `pve`, the recipe and the state backend exist (round trip passed 2026-10-07). The root holds only a marker: no VM is defined |
| Kubernetes bootstrap, Cilium, Argo CD | Not built |
| Secrets store, identity, applications | Not built |
| Data restore in a dedicated recovery mode, so restored data is never overwritten by freshly started workloads | Designed, not built |

Each later phase adds its restore runbook under `docs/runbooks/` and its rows to this document.

## Targets and measurements

| Item | Target | Measured |
|---|---|---|
| Hypervisor reinstall, from reboot into the installer to the host answering | - | About five minutes (2026-10-06) |
| Hypervisor back, configured, backups armed | One working day | Not measured |
| Recovery point of the hypervisor's configuration | 24 hours | Depends on the backup server VM running at 02:30. `pbs-host-restore list` on the hypervisor shows the newest snapshot |
| Workstation side rebuilt | - | Not measured |

Targets of the design for the later phases, until measured: platform back in one working day, data in two; recovery point 24 hours for volumes, 6 hours for the identity database and the secrets store.

## Open

| Item | What closes it |
|---|---|
| No off-site copy of any backup | The off-site repositories of the later phases (ARCHITECTURE.md section 12) |
| No rebuild after a loss has been rehearsed: hypervisor through the backup server VM as builder, the manual fallback, the backup server VM with a kept datastore, the workstation, both | One drill per row of the drill log below; the full drill is the gate of Phase 15 |
| Opening a session from the recovery keys on a new workstation has no recipe | A recipe or a rehearsed runbook step |
| [operator-key-compromised.md](docs/runbooks/operator-key-compromised.md), the runbook for a stolen workstation, is written but has never been drilled | A drill, recorded in the phase record |
| The whole-database restore has only been checked in a scratch directory, never put in place on a host | A drill once the first guest exists (Phase 5) |
| The deny test of the backup path's fences passed with the management window open (2026-10-07), not yet with it closed | `just test-fences` ending with `fences hold` after a plain run of `pbs-vm.ps1`, recorded in [docs/phases/phase-3.md](docs/phases/phase-3.md) |
| Recovery of the OpenTofu state from the kept copy has not been rehearsed | A rehearsal of [docs/runbooks/tofu-offline.md](docs/runbooks/tofu-offline.md) while the root holds only its marker |

## Drill log

| Date | Scenario | Result | Time taken |
|---|---|---|---|
| 2026-10-06 | Planned reinstall of the running hypervisor: media built on the host, one-time boot into the installer, no hands on the machine | Passed, with the media script as it was that day. The script has changed since; no later run is recorded | About five minutes for the install |
| 2026-10-06 | Restore of `etc.pxar` into a scratch directory, before and after the key rotation | Passed: five files compared equal to the live ones | - |
| 2026-10-07 | Backup, then restore of all three archives into scratch directories; integrity check of the restored cluster database | Passed. The database was not put in place on a host | - |
| - | Hypervisor rebuilt after a loss, image built on the backup server VM | Not run | - |
| - | Hypervisor installed by the manual fallback | Not run | - |
| - | Backup server VM rebuilt, datastore kept | Not run | - |
| - | Workstation rebuilt, including new keys from the recovery keys | Not run | - |
| - | Both destroyed | Not run | - |
