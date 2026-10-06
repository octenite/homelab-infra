# Phase 3 gate record: hypervisor

Status: **in progress on 2026-10-07; the gate is not closed.** Everything in `phase-3-plan.md` is built. Both host plays were applied on 2026-10-07 and a second run of each changes nothing. The deny test of the backup path passes with the management window open, and the OpenTofu state round trip passed. The workstation hardening is applied and the deny test passed again after the restart, with the window closed. One item still gates the phase: the result of the 24-hour soak of the direct link (G3). It is listed under "What still gates closing the phase". Dates are 2026-10-06 unless stated.

In this record "engineer" is whoever runs the plays from the workstation with a session open. The backlog calls the same role "operator".

## Plan against result

| Plan step | Planned gate | State on 2026-10-07 |
|---|---|---|
| 3.1 Install media | Answer file validates; image checksum matches; stick identified by serial | **Done.** Changed since: the builder is `just pve-media validate`, `iso`, `prepare`, `reboot`. The `iso` mode for a dead hypervisor is new and untested with the backup server as builder (backlog B27) |
| 3.2 Reinstall | Host answers at 10.0.10.10 with a new host key; root logs in with the lab key only; layout as planned | **Done.** Changed: root has no SSH login at all after the bootstrap play. The account `ops` is the only SSH login |
| 3.3 Measurements | Recorded here; worker VM size decided | **Done.** Idle memory measured again on the finished host on 2026-10-07 |
| 3.4 Ansible | Each play idempotent; deny tests from the servers and trusted networks; host without guests at or under 1.5 GiB | **Done** for both plays. Deny tests from the management and trusted networks passed. The servers network has no guest yet: deferred to Phase 5 (backlog B26). The memory gate is missed: 1.85 GiB used on the finished host, so the worker VM is created at 8.5 GiB, as the design foresaw. Changed: the host serves time to the two Talos node addresses, not to the whole servers network |
| 3.5 Backup server VM, first backup, restore | Restore verified; the backup job pings the dead-man's switch | **Built, restore verified.** The owner confirmed the notifications. The pings succeed as seen from the host. The deny test passed with the management window open and, after the restart, with it closed. Changed: the VM is Generation 1 (X7) and is started by hand. The fallback is the workstation's forward of port 8007 over the home network (E14) |
| 3.6 OpenTofu state backend | Init, apply and state pull round trip | **Done** on 2026-10-07: init, apply, encrypted copy kept, second plan without changes. Changed: the kept state copy is the bucket's object as stored (ciphertext), not the output of `tofu state pull`, which is plaintext |
| 3.7 2.5 GbE link | Link up at 2.5 Gbit/s, or fallback F1 recorded | **Link up at 2.5 Gbit/s**, held by a keep-alive. The 24-hour soak ends 2026-10-07 21:10 (G3). F1 was not needed |

Dropped: nothing. Two statements of the plan no longer hold. Its rollback table says the recovery key stays authorised by the installer; as built it is authorised for `ops`, and a key list is refused unless it holds two keys with one loaded in the agent. Its list of secrets names the root password only; the full list is in `docs/security/secrets-register.md`, sections 3 to 6.

Pull requests of the phase: 12 (reinstall and host play), 13 (bridges, exporters), 14 (access), 15 (second factor), 16 (backup server VM), 17 (hypervisor backups), 18 (two workstation addresses), 19 (keep-alive), 20 (OpenTofu root), 21 (fixes), 22 (Telegram, datastore disk by label), 23 (review fixes).

## What was done

| Step | Result |
|---|---|
| 3.1 Install media | Built on Node 1 itself from the answer file in Git and the private inventory, embedded in the official 9.2 image (checksum verified), written to the stick and read back for comparison. The first attempt failed twice: the host's RAM disk was too small for the image, and the stick, an SD card in a USB reader on an extension cable, reset under load. On a rear port the same reader passed a 256 MiB write and read test and the install media verified |
| 3.2 Reinstall | One-time boot into the installer, no hands on the machine. The new system came back on 10.0.10.10 after about five minutes as `pve1`, booting UEFI, with the planned layout: 20 GiB root, 4 GiB swap, 190.7 GiB thin pool. The installer authorised both SSH keys for root. The installer boot entry was removed afterwards. Since pull request 23 the first task of the host role also overwrites the installer image on the stick |
| 3.3 Measurements | Below |
| 3.4 Ansible (pull request 12; as it stands after pull request 23) | Bootstrap play: operator account `ops` with both keys, root login over SSH closed. Host play: free Proxmox repository, Intel microcode, unattended upgrades from the Debian security origins only, SSH key-only on the management address for `ops` only, chrony with the router as the only source and serving the two Talos node addresses, swap as a safety net, KSM off, persistent capped journal, host firewall with policy DROP and the exceptions E2, E6, E7 and E13. Root's key file is Proxmox's own link and holds no operator key |
| 3.4 Bridges and metrics (pull request 13) | `vmbr0` made VLAN-aware with the servers VLAN tagged for guests, `vmbr1` created on the 2.5 GbE port with the point-to-point address, IP forwarding off. Applied through the guarded path: parse first, revert timer armed, reload detached, confirmed only after the host answered with the expected VLANs and bridges. The SSH session did not drop. `node_exporter` 1.12.1 and `smartctl_exporter` 0.14.0 from the `prometheus.prometheus` collection on the management address, and a timer that feeds thin-pool usage to the textfile collector |
| 3.4 Access (pull request 14) | Custom roles `TerraformProvisioner` and `KubernetesCSI`, pool `talos`, the owner's `octenite-admin@pve` as the only Administrator (password generated into the private inventory), four automation users with scoped entries, and four privilege-separated tokens with a 12-month expiry. Their secrets went straight into `private/proxmox/tokens.sops.yaml` without being displayed. Since pull request 23 `TerraformProvisioner` has no `Sys.Modify`, and its network grant is the single path `/sdn/zones/localnetwork/vmbr0/50` |
| 3.5 Backup server VM (pull request 16) | Node 2 inventoried (B14 closed). Owner decisions: fallback path over the home network approved (E14), WSL capped at 5 GB, the VM at 4 GiB fixed and started by hand. `scripts/node2/pbs-vm.ps1` converges the VM, its two switches, NAT, port ACLs, firewall rules and port forwards. The unattended image is built on the hypervisor and copied to F: (`just pbs-media`). PBS 4.2 installed after three findings, each now encoded in the script. A Generation 2 VM gives the installer no storage or keyboard: the VM is Generation 1 (X7). The DVD first in the boot order re-runs the installer for ever: the disk boots first and falls through when empty. With two disks attached the installer's disk names swap between boots, and it once installed onto the datastore disk: the datastore disk is detached during the install, and the role refuses any disk that holds anything but the datastore. Bootstrap and host plays: operator account, free repository, SSH key-only, nftables input policy drop except the two paths, datastore `pbs1` on a labelled ext4 partition, prune daily, garbage collection weekly, verification monthly. Fallback path proven from the hypervisor through router, Windows firewall and port forward: HTTP 200 |
| 3.5 Hypervisor backups (pull request 17) | `just pve-backup-init` created the backup server's user and token (both hold `DatastoreBackup` on the datastore, because a token holds the intersection of its own and its user's entries) and the storage entry `pbs-node2` with a generated client-side encryption key. Token and key went into the private repository without being displayed. The host role keeps the client credentials (root only), `pbs-failover.timer`, which every five minutes points the name `pbs1.internal` at the direct link when the server answers there and at the workstation's forward otherwise, and `pbs-host-backup.timer`, the nightly 02:30 backup of `/etc` (with `/etc/pve`), the cluster database and `/root` (installer images excluded). First backup 30 s; second 0.3 s and 6.4 MiB. First restore test: `etc.pxar` of the latest snapshot into a temporary directory, 768 files, five files compared equal to the live ones. Runbook: `docs/runbooks/restore-host-config.md`. Since pull request 23 the cluster database is archived as one consistent `config.db` |
| 3.5 Notifications and dead-man's switch | Both hosts send their native notifications to Telegram through a webhook target (pull request 22). The nightly backup pings a healthchecks.io check after a successful run only; any failure exits before the ping |
| 3.6 OpenTofu (pull request 20) | Root `pve` with a marker resource, state encryption enforced (pbkdf2 and aes_gcm), the wrapper `just tofu <root> <command>`, and `just tofu-lint` in CI. Passphrase and bucket keys are stored. The backend was initialised on 2026-10-07, once the owner had named the bucket; see "OpenTofu state round trip" |

## Measurements

| Item | Value | Effect on the design |
|---|---|---|
| Memory visible to Linux | 15918 MiB (15.54 GiB) | As assumed |
| Idle memory used, host alone, after the first configuration | 1.55 to 1.9 GiB over several readings | Above the 1.5 GiB gate; the worker VM is created at 8.5 GiB, as the design foresaw. Read before the exporters, the timers and the keep-alive existed |
| Idle memory used, finished host without guests, 2026-10-07 01:22 | 1891 MiB used of 15918 MiB; 14027 MiB available; swap unused | Still above the gate. The budget keeps 1.9 GiB for the host and the 8.5 GiB worker |
| Onboard port | 1000 Mbit/s, `r8169`, now named `enp3s0` | Fine |
| 2.5 GbE port, `enp2s0` | No link at the first reading; 2500 Mbit/s since the cable was replaced | See "Direct link" |
| Microcode | Revision 0x21, loaded early from 0x19; one vulnerability (SRBDS) remains without a fix | Exception X13 stands |
| Thin pool, synchronous writes (8 KiB sequential, fdatasync on every write, 30 s) | About 1480 writes per second; fsync latency p99 2.2 ms, p99.9 33 ms; write latency p99 5 ms | Passes the 25 ms gate for etcd; the SSD stays |
| Time | Synchronised to the router, stratum 3 to 4. The host serves the two Talos node addresses, with a local fallback at stratum 10 | As designed (E13) |

## Direct link (step 3.7)

Resolved in two steps on 2026-10-06.

1. The first cable had only two working pairs: 100 Mbit/s on the laptop's built-in port. A new cable gave 2.5 Gbit/s on the USB adapter.
2. The adapter still dropped the link 10 to 50 s after the last frame and never brought it back by itself. It powers its PHY down when idle. Proof: the link held for ten minutes under one ping per second and fell ten seconds after the pings stopped.

The hypervisor now runs `pbs-keepalive.service`: one small packet per second towards the backup server. Five seconds apart was too slow; the link fell again. The link has been up at 2.5 Gbit/s since the keep-alive was installed at 21:10, with one explained interruption: the workstation was restarted on 2026-10-07 at 02:21, the link fell at 02:21:23 and came back by itself at 02:21:42, at 2.5 Gbit/s, and the name `pbs1.internal` still pointed at the direct link afterwards. The 24-hour soak ends on 2026-10-07 at 21:10 and its result is not recorded yet (G3). The search for a driver setting is backlog B21.

## Host firewall tests

Run on 2026-10-06. The probe from OpenWrt devices uses their SSH client against each port: a timeout means the packet was dropped, a refusal means it reached the host, anything else means the port answered. Controls on the router itself: its own SSH port reads as open, a closed port reads as refused.

| From | Port | Expected | Result |
|---|---|---|---|
| Workstation | SSH, web interface | allow | pass |
| Router (management network) | SSH, web interface, console ports, migration, exporter | drop | pass |
| Router | ping | allow | pass |
| Access point 1 (management network) | web interface | drop | pass |
| Access point 1 | SSH | drop | dropped ("Operation timed out"), repeated once the wired link was back |
| Access point 1 | ping | drop | pass |
| Workstation | exporters (9100, 9633) | drop | pass: the connection fails from the pinned address, which is not in E7 |
| Workstation | SSH after the bridge change | allow | pass |

Not probed: the servers network, which has no guest yet (backlog B26). After pull request 23 the rule set was read back on the host, not probed again from these sources (see "Apply and verification").

### The workstation's address: what was tried and what stands

1. During the first probe the workstation's dock adapter disappeared. Its traffic moved to Wi-Fi with another address, and every firewall rejected it. That confirmed exception E2 from the wrong side: nothing in the lab answers a workstation that is not on its pinned address.
2. The owner asked to work from Wi-Fi as well and chose, from three options, to bind the pinned address to the Wi-Fi adapter too. It worked with the dock unplugged, after the old lease was released and renewed once from an elevated prompt.
3. Docking with Wi-Fi still up broke it. The router offered the pinned address to the dock port, Windows refused it as a duplicate because its own Wi-Fi still held it, and the laptop fell back to a link-local address.
4. A Windows connection policy that drops Wi-Fi while a wired link is up made it worse. Windows drops Wi-Fi only once the wired link has connectivity, which it could not get. The laptop lost both links.
5. Decision the same evening, which stands: the dock port keeps 192.168.1.196 and the Wi-Fi adapter has its own reservation, 192.168.1.197. Every workstation rule on the router, the access points and the hypervisor names both addresses. The backup fallback tries both. Both links may be up together. `scripts/node2/workstation.ps1` removes the connection policy and keeps only the power settings of the direct-link adapter.

The alternative, a key-bound WireGuard tunnel on the router, is backlog B20.

## Reviews and what they changed

Two read-only reviews ran after the build. The first covered everything built in Phase 3 and returned 58 findings. The second covered the fixes and returned 22. The deny test of the backup path added one more defect. All fixes are in pull request 23 (commit `397a592`, merged 2026-10-07). CI is green on it, including the new PowerShell lint.

| Area | Change |
|---|---|
| Workstation fences | Defect found by the deny test: many Windows services share one process on this machine, so a built-in service-scoped allow rule admitted the forwarded ports from any source. `pbs-vm.ps1` now maintains block rules, which win over allow rules, converges every `homelab-*` rule by content and removes rules it does not know. The SSH forward on port 2222 exists only while the management window is open (`-Manage`). Destructive switches need a typed phrase |
| Deny test | `just test-fences` probes from the hypervisor, the router, WSL and the backup VM. It fails when one probe disagrees and when it could not probe |
| Backup encryption key | `just pve-backup-init` never generates a second key and never overwrites a recorded one. A rebuilt hypervisor gets the recorded key. A difference between host and record stops the play |
| Backup token and fingerprint | After a rebuild of the backup server the play gives the existing storage entry the new token and the new certificate fingerprint, then checks that the storage is active |
| Host backup | One consistent copy of the cluster database (SQLite online backup, integrity-checked) instead of three live files. The failover probe is an HTTPS request, because the port forward accepts a bare connection while the VM is off. `pbs-host-restore` refuses `latest` on a rebuilt host. `just pve-apply` fails at its end when a host that had backups has none armed |
| Hypervisor hardening | Unattended upgrades take Debian security only. Time is served to the Talos nodes only. The accept rule for the console ports is gone. The SMART exporter keeps `CAP_SYS_RAWIO` only |
| Access | Unmanaged users and tokens stop the play. Entries that Git no longer grants are removed. `TerraformProvisioner` lost `Sys.Modify`. The administrator's password goes in on standard input |
| SSH keys | The keys of `ops` follow the inventory on every run of `just pve-apply` and `just pbs-apply`, behind the two-key guard. Root has no authorised operator key on either host |
| Install media | The role's first task overwrites the installer image on the recorded stick and removes its boot entry. `just pve-media iso` can build on the backup server when the hypervisor is dead |
| Backup server | A datastore that is listed without its chunk store stops the play. Existing chunks are attached again, never created over. The mount has `nofail`. Notification secrets are root only |
| Tooling | The session, secret, play, OpenTofu and test recipes are one line over scripts in `scripts/ops`, `scripts/tofu` and `scripts/tests`. `just pve-bootstrap` and `just pbs-bootstrap` exist. The session expires at a wall-clock deadline. `just setup` puts the private repository on its main branch and `just private-status` checks it. The OpenTofu state copy is the bucket's ciphertext. CI parses the PowerShell scripts and renders the answer-file templates |

## Apply and verification, 2026-10-07

| Step | Result |
|---|---|
| `just pve-apply` | 19 changed. Second run: changed=0 |
| On pve1 afterwards | Install stick blank, no `pve-install` boot entry. Unattended-upgrades origins: Debian security only. Root's authorised-keys file is the link into `/etc/pve` and holds only the node's own key. chrony allows the two Talos node addresses only. Firewall rules E2, E6, E7 and E13 plus the X10 drops, no accept for the console ports. SMART exporter active with `cap_sys_rawio` only and still exporting (106 series, disk healthy). Token `terraform@pve!tofu` without `Sys.Modify`; network grant on `/sdn/zones/localnetwork/vmbr0/50` only. No failed units |
| `just pbs-apply` | 5 changed. Second run: changed=0 |
| On pbs1 afterwards | Mount line with `defaults,nofail,x-systemd.device-timeout=10s`. Prune job (keep 7 daily, 4 weekly, 3 monthly) and verification job (monthly, outdated after 30 days) present. `notifications.cfg` root:backup 0640, `notifications-priv.cfg` root:root 0600. No authorised key for root. No failed units |
| `just pve-backup-init` | changed=0. The host's key equals the recorded key. Storage active |
| Backup | Ran over the direct link (10.0.99.3). The staging directory of the database copy was removed afterwards |
| Restore of all three archives into scratch directories | Restored `config.db`: `pragma integrity_check` returns ok; 42 rows in the tree table, the same as the live database; it holds `storage.cfg`, `user.cfg` and `datacenter.cfg`. Restored `/etc` files compared equal to the live ones. A second restore into an existing directory was refused |
| Notifications, after the tighter file modes | pbs1: test message delivered ("notified via target telegram"). A verification job (2 of 2 snapshots, 0 errors) delivered its notification. pve1: test message accepted. The owner confirmed on 2026-10-07 that the messages arrive in Telegram |
| Dead-man's switch | The backups of 2026-10-06 22:00 and 2026-10-07 00:32 ran with the ping URL in place and logged no "backup ping failed". The script calls the URL with `curl -f`, so the service answered each ping with success. Not checked on the service's own dashboard |

## Deny test of the backup path

`just test-fences` (`scripts/tests/backup-fences.sh`). "Before" is the run of 2026-10-07 with the management window open and the workstation still on the rules of the earlier script version: 51 probes, 12 of them disagreeing, listed here.

| From | To | Expected | Before | After |
|---|---|---|---|---|
| Router (a trusted-network address that no rule admits) | Workstation 192.168.1.196, ports 8007 and 2222 | silent | **Fail:** both answered | Pass: silent |
| Hypervisor, over the direct link | Workstation 10.0.99.2, ports 135, 2222 and 8007 | filtered | **Fail:** all three open | Pass: filtered |
| Backup VM | Workstation 10.0.98.1, ports 135, 2179, 2222 and 8007 | filtered | **Fail:** all four open | Pass: filtered |
| WSL (not the hypervisor's address) | Port 8007 on the workstation's home address, on the WSL gateway address and on 10.0.99.2 | closed | **Fail:** open on all three | Pass: filtered |
| Hypervisor, router, WSL and the backup VM: the other 39 probes | The backup server, the workstation's home addresses, the hypervisor, the lab through the VM's NAT leg, the internet | As the script states | Pass | Pass. The backup VM still reaches a public resolver and the package mirror through its NAT leg |
| Total | | Every probe as expected; the script ends with "fences hold" | **12 of 51 probes disagree.** Ten are the forwarded ports 8007 and 2222 answering a source that no rule admits. Two are Windows' own ports 135 and 2179 answering the direct link and the backup VM. The new block rules for those two source ranges cover all twelve | **Fences hold: 51 probes, all as expected.** Run on 2026-10-07 after the owner's elevated run of the script, management window open |

The "After" run had the management window open.

Second run, 2026-10-07 02:26, after the owner had run `scripts\node2\workstation.ps1`, restarted Windows, started the VM and closed the window with a plain run of `pbs-vm.ps1`:

| State checked | Result |
|---|---|
| Service split threshold | 3670016 KB, the Windows default. The port-forward service (`iphlpsvc`) runs alone in its process |
| Page file encryption | On |
| WSL | 4919 MiB memory, no swap |
| `just test-fences`, management window closed | **Fences hold: 22 probes, all as expected.** Port 2222 is closed from every vantage point. The 29 probes from inside the backup VM are skipped, because they need the window; they passed in the run before the restart, and the rules they test did not change |

## OpenTofu state round trip (step 3.6)

Run on 2026-10-07, after the owner named the bucket. The backend settings are in `private/opentofu/backend.hcl`.

| Step | Result |
|---|---|
| `just tofu pve init` | Backend "s3" configured against the Backblaze B2 endpoint |
| `just tofu pve plan` | One resource to add: the marker |
| `just tofu pve apply` | Applied. The wrapper reported "state copy saved (ciphertext, as stored in the bucket)" |
| The kept copy, `private/opentofu/state-copies/pve.state.json` | Its keys are `encrypted_data`, `encryption_version`, `lineage`, `meta` and `serial`. It holds no resource list and not the marker's value. The private repository's guard accepts it |
| `just tofu pve plan`, again | "No changes"; exit code 0 with `-detailed-exitcode` |
| `just tofu pve state list` | `terraform_data.root` |
| The bucket key's scope | A call that lists all buckets is refused (AccessDenied). The state bucket holds one object, `pve/terraform.tfstate` |

Not done: a rehearsal of `docs/runbooks/tofu-offline.md` with the kept copy, and a rotation of the state passphrase (backlog B29).

## Incidents

**Backup encryption key displayed, key replaced (2026-10-06).** While moving the storage entry onto the hosts-file name (PVE forbids changing a storage's server after creation, which the failover design had assumed), a manual `pvesm add` with the key passed as a value instead of a file path made the tool echo the key JSON into the operator's session transcript. The key was treated as exposed. The entry was created again with a fresh key the same hour, the two test snapshots made with the old key were deleted and garbage-collected, and the private repository holds the new key. Nothing of value was ever encrypted with the old key. Fixes: the play passes keys through a root-only file that is shredded afterwards, and since pull request 23 it never replaces a recorded key.

**Ping URL of the dead-man's switch displayed (2026-10-07).** The healthchecks.io ping URL appeared once in a session transcript. Its sensitivity is low: it can only report a backup as done. The owner decided on 2026-10-07 not to regenerate it.

## Token scope tests

Run on 2026-10-06 from the workstation against the API with the stored tokens. The expected answer is 200 for a call inside the scope and 403 outside it.

| Token | Inside scope | Outside scope |
|---|---|---|
| `drift@pve!weekly` (auditor) | version, user list: 200 | create a pool: 403 |
| `prometheus@pve!exporter` (auditor) | node status: 200 | - |
| `terraform@pve!tofu` | pool `talos`, storage list, next VM id: 200 (the pool answered 403 until `Pool.Audit` was added) | - |
| `kubernetes-csi@pve!csi` | storage content: 200 | node status: 403 |
| no token | - | version: 401 |

These calls predate the removal of `Sys.Modify` and the narrower network grant. After that change the privilege list and the grant were read back on the host; the calls were not repeated, and no negative call was made for the OpenTofu token (backlog B31).

## Defects found and fixed

| Defect | Fix |
|---|---|
| Proxmox has no `sudo`, and its subscription repository blocks `apt update` | The bootstrap play fixes the repositories and installs sudo before anything else |
| The cluster filesystem under `/etc/pve` refuses permission changes and atomic replacement, which Ansible's copy needs | Firewall and notification files are compared with their wanted content and, only when they differ, written in place |
| The cluster-wide firewall file rejects `log_level_in` | Removed from that file |
| pve-firewall adds built-in rules that admit the host's own subnets to SSH, the web interface, the console ports and migration, and those subnets cannot be removed from its "management" set | Host rules run first, so an explicit drop for the rest of the management network and for the direct link on those ports follows the workstation's accept rules (X10) |
| A failure late in the play left services on their old configuration (chrony, sshd) | Pending restarts are applied before the bridge change and before the play ends, and also when a later task stops the play |
| The media builder required the stick's serial even for the reboot command, so the first reboot never happened | Fixed |
| ifupdown2 3.3 fails its syntax check on `bridge-fd 0`, which the installer itself writes; the installed file fails the same check | The managed file carries no forward delay (meaningless with STP off); the parse gate stays strict |
| The upstream `smartctl_exporter` unit runs as an unprivileged user without access to the disk, so it exported no SMART data | A systemd drop-in grants the disk group and the raw-command capability, nothing else |
| The textfile directory was fought over by two roles (owner and mode), so the play was never clean | The host role creates it with the mode the exporter role wants and leaves ownership to that role |
| On the workstation a built-in allow rule admitted the forwarded ports from any source, because many services share one process | Block rules in `pbs-vm.ps1`. The root cause is fixed by `scripts/node2/workstation.ps1`, which restores the Windows default of one service per process (owner decision 2026-10-07, backlog B22); it takes effect with the next restart |

## What still gates closing the phase

| # | Gate item | Who | Closes when |
|---|---|---|---|
| G1 | Deny test of the backup path | Owner, then engineer | The owner runs `powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Manage` in an elevated prompt. The engineer runs `just test-fences`; it must end with "fences hold" and the "After" column above is filled. The owner then closes the window with a plain run of the script, and a second `just test-fences` passes with the window closed. **Closed 2026-10-07:** 51 of 51 with the window open; 22 of 22 with the window closed, after the restart that restored one service per process |
| G2 | OpenTofu state backend and round trip | Owner, then engineer | The owner gives the bucket name, region and endpoint. They go into `private/opentofu/backend.hcl`. Then `just tofu pve init` and `just tofu pve apply` succeed, the wrapper reports "state copy saved (ciphertext, as stored in the bucket)", the copy is committed to the private repository, and a following `just tofu pve plan` reports no changes. **Closed 2026-10-07** |
| G3 | 24-hour soak of the direct link | Engineer | After 2026-10-07 21:10: no link loss on `enp2s0` since 2026-10-06 21:10 other than a restart of the workstation, and `ethtool enp2s0` on pve1 shows 2500 Mb/s. The result is recorded under "Direct link". If it failed, fallback F1 is recorded instead |
| G4 | Idle memory of the finished host | Engineer | `free -m` on pve1 without guests is recorded under "Measurements" and the budget is re-based on it. **Closed 2026-10-07** |
| G5 | Dead-man's switch proven | Owner, then engineer | The owner regenerates the ping URL in healthchecks.io. It is stored and deployed (`docs/security/secrets-register.md`, R9). After the next backup the owner confirms that the check shows the ping. **Closed 2026-10-07** on the host's evidence (see "Apply and verification"); the owner waived the regeneration |
| G6 | Notifications received | Owner | The owner confirms that the test messages of pve1 and pbs1 arrived in Telegram. **Closed 2026-10-07** |

## Open, not gating

| Item | Who | Where it is tracked |
|---|---|---|
| Second factor for `root@pam` on pbs1 | Owner | Backlog B24 |
| Restore the default service-process split on the workstation | Done 2026-10-07: set by `scripts/node2/workstation.ps1`, in effect since the restart | Backlog B22, closed |
| Swap, pagefile and hibernation hardening for the session key (X23) | Done 2026-10-07: WSL swap off, page file encrypted, hibernation off; in effect since the restart | Backlog B23, closed |
| Off-site copy of the backups; the 3-2-1 rule is not met | Engineer proposes | Backlog B25 |
| Deny test from the servers network | Engineer | Backlog B26, Phase 5 |
| Password-manager copies to confirm: the OpenWrt root passwords | Owner | Secrets register, O2 |
| Backup server VM started by hand: the nightly backup fails while it is off | Owner | Backlog B32 |
| CSI entries on the worker VMs, once their IDs exist | Engineer | Phase 7 |

## Closed

Both hypervisor passwords are in the owner's password manager. The owner reported on 2026-10-06 that the TOTP recovery keys of both hypervisor accounts are created and stored there, and that the entry for the backup encryption key was replaced with the current key after the rotation. On 2026-10-07 the owner confirmed holding the backup encryption key and the backup server's root password, and decided to enrol the second factor for the backup server's root later (backlog B24). The owner enrolled TOTP for `octenite-admin@pve` and `root@pam`, after which the host play switched both realms to require a second factor. The role does that only once every password user of a realm has enrolled, so a rebuild cannot lock the owner out. Verified afterwards: the four tokens still answer (a realm requirement never applies to tokens), and password logins still receive a ticket, now flagged for the second step.

The owner created the Telegram bot, the healthchecks.io check and the Backblaze application key. Their secrets are stored in the private repository.
