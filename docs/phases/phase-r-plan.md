# Phase R plan: remote administration

Status: **approved by the owner on 2026-10-09, with every recommended default (D1 to D12); in progress: R.0, R.1 and R.2 passed on 2026-10-09, R.3 is next.** Proposed on 2026-10-08, amended on 2026-10-09. The decision record is `docs/adr/0005-administrative-access.md`. The household plan was approved the same day, so VLAN 31 is laid in R.5 and R.6. The owner asked for it on 2026-10-08 and chose Tailscale. A cloud server is a later add-on and not part of this phase. Phase R runs before Phase 5. On 2026-10-09 the owner widened the purpose to household use from away. That is the second part, `phase-r-household-plan.md`, built after this one has passed its gate. This document is the administration path. The changes the wider purpose makes here are marked "amended" and listed at the end of that plan. VLAN 31 is laid in R.5 and R.6 only if the household plan is approved before R.5.

Goal: the owner can administer the hypervisor from the laptop on mobile data or public Wi-Fi, with the same tools as at home, and from nowhere else. At home nothing changes.

The design conditions are those of `docs/ARCHITECTURE.md` section 6, "Administration". Where the research of 2026-10-08 corrects them, the correction is listed under "Corrections to the approved design". The research is in `docs/research/2026-10-08-remote-access-research.md`. The draft of this plan was reviewed by three independent reviewers; their findings are worked in.

## What it is

```
laptop (away)            Tailscale                 home
+-----------+   encrypted, both sides dial out   +--------------------------------------------+
| Windows   | ---------------------------------> | container remote1, VLAN 30, 10.0.30.10      |
| Tailscale |                                    |   opens ordinary TCP connections            |
| WSL: ssh, |                                    |   router firewall, zone "remote", rule E15  |
| Ansible,  |                                    |     -> pve1 10.0.10.10   tcp 22, 8006       |
| OpenTofu  |                                    +--------------------------------------------+
+-----------+
```

- Nothing at home listens on the internet. The container and the laptop each connect outwards to Tailscale and meet there. That is what carrier-grade NAT allows.
- pve1 sees one source address, 10.0.30.10. It is never the workstation's home address, so the rules E1 to E3 are untouched and stay valid for home only.
- Four layers decide what is reachable. Each survives a different failure:

| Layer | Kept in | Survives |
|---|---|---|
| Tailscale policy | Git, applied to the Tailscale service | a mistake on the laptop. It does not survive a takeover of the Tailscale account |
| The container's own packet filter | Git | a policy that was widened by mistake or by an account takeover |
| pve1's firewall on the container's network device, with the address filter (amended) | Git | a compromised container: root inside it cannot remove this layer or take another address |
| The router's rules for the zone `remote` | Git | all of the above, and a compromised container. Nobody at Tailscale and nobody holding the account can change it |

- pve1 keeps its own locks. SSH needs the operator's key. The web interface needs password and TOTP. Its API also accepts the API tokens, which have no second factor; they are scoped, and they live in the private repository.

## Decisions needed from the owner

| # | Decision | Recommended | Alternatives, and the honest cost of each |
|---|---|---|---|
| D1 | What is reachable from away | pve1 only: SSH and the web interface. The cluster's API addresses are decided in the Phase 5 plan, the admin web listener in the phase that builds it | Also SSH to the router and the access points: under D6 no change to them is allowed remotely, so this buys reading only, and it puts root SSH on the device that enforces the segmentation within reach of the remote endpoint |
| D2 | Form of the home endpoint | An unprivileged container on pve1 with Tailscale in userspace mode. It needs no device and no special privilege, and SSH and HTTPS are TCP, which that mode carries. Costs: the vendor rates this mode "acceptable" in speed and newer than the kernel mode; the exposed process shares the hypervisor's kernel. If it fails its test, the choice of fallback comes back to you | A small VM: its own kernel, about 0.4 GiB more memory, taken from the worker. The Tailscale package on the router: does not depend on pve1, but it barely fits the flash, lags upstream, and puts remote access on the device that enforces the segmentation |
| D3 | Who creates the container | OpenTofu with the existing scoped token, in a root of its own. This is the first real use of the Proxmox provider and brings its groundwork forward from Phase 5 | An Ansible role now, moved into OpenTofu in Phase 5. Less new at once, but one guest outside the rule "OpenTofu owns guests" |
| D4 | Node signing, and which devices may sign (amended) | On, with the laptop as the only signer and the disablement secrets as the way out. The laptop must sign: signing and enabling are command-line actions, and the only other command-line device is the container, the most exposed machine. Your phone is an Android phone, which cannot sign, and under the household plan it is a daily client. Costs: every loss of the laptop's Tailscale state, by theft, disk failure, TPM reset or reinstall, ends in the disablement procedure at home; until then no device can be added or enrolled again, the laptop included. After a theft the thief's laptop can still sign: only your GitHub login keeps him from adding a device. The vendor recommends two signers. Whether signing can be enabled with one is checked in R.4 | The container as second signer: not verified for a tagged device, and advised against, because it is the exposed machine. Or no node signing: then anyone who takes over your GitHub account, or the Tailscale service itself, can add a device, and only the policy and the router rules stand behind that |
| D5 | The laptop's Tailscale key on an unencrypted disk | Tailscale's state encryption, bound to the laptop's TPM. It stops the key being copied off the disk. It does not stop someone who holds the whole laptop: the device must be removed from the network in every case. The laptop has a working firmware TPM (checked 2026-10-09). Cost: a TPM reset, which a firmware update can cause on this kind of TPM, means enrolling the laptop again, one policy change and, with the laptop as the only signer, the disablement procedure at home | Disk encryption with a start-up secret is the only thing that also stops someone who holds the laptop. You declined BitLocker for its performance cost. Or accept the plain key file |
| D6 | What may be changed while away | Allowed: everything on the cluster and its VMs from Phase 5; dry runs of the hypervisor play; the Tailscale policy. Refused by the tooling: real runs of the hypervisor plays, the install media, anything on the container. The router, the access points and the backup server are not reachable at all. These are guards against mistakes. They stop nobody who holds your key | Allow everything on pve1 and rely on its revert timer for the network. Its firewall has no revert; a mistake there waits for you to come home |
| D7 | Key expiry of your own devices | 90 days. Renewal needs only internet and your GitHub login. The travel check shows the date and warns two weeks ahead | 180 days, the vendor default |
| D8 | Outbound rules of the container | The smallest set: name lookups at the router and HTTPS to the internet. Every connection is then relayed through Tailscale's servers. Measure. Add two UDP rows only if a direct path really forms through the provider's NAT | Open UDP from the start: possibly faster, one wider rule that may buy nothing |
| D9 | Backup of the container | None. It holds no data and is rebuilt from Git. A rebuild needs you at home for five small steps: deletion protection off, the old entry deleted in the Tailscale console, a browser login for the new one, one signing command, the new SSH host key accepted | Back it up: a restore keeps its identity, and its network key, which does not expire, sits in the backups |
| D10 | Tailscale policy as code | A second OpenTofu root with the official Tailscale provider. Policy, tests and settings are in Git and applied from the workstation. It needs one credential that does not expire: an OAuth client limited to the policy file and the settings. A leak lets someone change the policy among signed devices and cut remote access. It cannot add a device, change node signing or touch a router rule | Keep the policy in Git and paste it into the web console by hand. No credential, and nothing proves the console matches Git |
| D12 | When the administration container runs (amended) | Only while the laptop is away: `travel.ps1 -Away` starts it and proves the path, `-Home` stops it and pauses its health check. At all other times the router and pve1 have nothing to admit, which matters because only the Tailscale policy keeps the phone off this container | Always on: nothing to forget before leaving. If you leave without running `-Away`, the recommended form gives no administration path until you are home |
| D11 | Drill of the lost-laptop procedure before the first trip | Yes, reduced: the Tailscale steps and the replacement of the operator's SSH key on every host are done for real; the rotation of the stored secrets is walked through on paper. The runbook it ends in has never been run, and backlog item B30 asks for a rehearsal before Phase 5 | Waive it, recorded. The first run of the procedure is then a real loss |

## Needed from the owner

| Item | When | Why |
|---|---|---|
| Your GitHub account has two-factor login and stored recovery codes | before R.2 | It becomes the root of trust for the network. Tailscale cannot check or enforce this |
| Where your GitHub second factor and pve1's second factor live | answered 2026-10-09: a synced authenticator app and synced passkeys in the password manager, on the laptop and the phone; pve1's second factor in the same authenticator. See H4 of the household plan | The phone is an Android phone (answered 2026-10-09). GitHub has two-factor login and recovery codes (answered 2026-10-09). The second factor must work with neither the phone nor the laptop: a hardware key, or printed recovery codes carried apart from both. The lost-laptop procedure is done from the phone, the lost-phone procedure from the laptop |
| The output of `Get-Tpm` | answered 2026-10-09 | Present, enabled and ready; a firmware TPM. It showed a restart pending, which is cleared before R.3 |
| A Tailscale account, created by signing in with GitHub; one OAuth client created in its console with the two scopes of D10 | R.2, with me guiding | No tool can do the first login for you |
| The phone enrolled in the network | R.3 | The test device that the policy does not name. It gets its first grant only in the household plan, after this gate is recorded |
| A password-manager entry and a printed copy of the disablement secrets | R.4 | The only way out if the signer is lost. Never in Git |
| A browser login for the container, and one signing command on the laptop | R.8 | The container joins the network with no stored key |
| A phone hotspot, with the dock cable and the direct link unplugged | R.10 | The tests must run from outside |

The whole build is several sessions at home. The container can be configured only from the two home addresses. The steps that can interrupt something are R.5 and R.6, about 60 minutes together, at the wired workstation.

## What the household will notice

| Step | Effect |
|---|---|
| R.5 | The router restarts its network: wired and Wi-Fi clients lose their connection for a few seconds |
| R.6 | Nothing, unless the bridge change fails: then pve1 is unreachable for up to three minutes and restores itself |
| Everything else | Nothing |

## Addresses and rules

| Item | Value |
|---|---|
| VLAN 30, zone `remote` | 10.0.30.0/24, router 10.0.30.1, no DHCP, no IPv6 |
| VLAN 31, zone `home_remote` (amended) | 10.0.31.0/24. Laid here: tagged on lan1, the interface with 10.0.31.1, its DHCP section ignored, no IPv6, and the zone in the zone list only. No rule, not even name lookups; no guest; no right for the token. The household plan fills it |
| Container `remote1` | 10.0.30.10, static; name lookups at 10.0.30.1 |
| Router port | VLAN 30 tagged on lan1, the trunk to pve1. No other port, no Wi-Fi network |

New firewall exceptions on the router, each one commented rule:

| ID | From | To | Ports |
|---|---|---|---|
| E15 | 10.0.30.10 | pve1 10.0.10.10 | tcp 22, 8006 |
| E16 | 10.0.30.10 | internet | tcp 443. The container's package sources use HTTPS, so port 80 stays closed. After D8 perhaps udp 3478 and udp from port 41641 |
| E17 | workstation 192.168.1.196, .197 | 10.0.30.10 | tcp 22: configuring the container, from home only |

The zone gets name lookups from the router and nothing else: no path to any other zone, and no path from any zone into it except E17.

On the other devices:

- **pve1**: its firewall admits 10.0.30.10 to tcp 22 and 8006, and drops the rest of 10.0.30.0/24 on the management ports, like the existing X10 rows. The host never gets an address in VLAN 30, not even for a test.
- **Container**: its own nftables table, default drop. Outbound it allows exactly E15 and E16, and only for the user that runs Tailscale. SSH listens on 10.0.30.10 only and accepts the two workstation addresses. Kernel forwarding stays off. Tailscale runs as an unprivileged user, so a compromise of that process cannot remove the table.
- **Tailscale policy**: grants only. The laptop's own tailnet address may reach 10.0.10.10 on tcp 22 and 8006 through the container's tag. Nothing may reach the container or the laptop. Tests in the file assert the allowed and the denied cases, and a failing test makes Tailscale reject the file.
- **Laptop**: Tailscale accepts no inbound connection, takes no name service from Tailscale, does not start by itself and does not update itself.

Tailnet settings, with where each is set:

| Setting | Value | Set by |
|---|---|---|
| Policy file | grants and tests from Git | OpenTofu |
| Key expiry of user devices | per D7 | OpenTofu |
| Device approval | on until node signing is enabled, then off: the two cannot be on together | OpenTofu |
| User approval | on | OpenTofu |
| Name service of the network | off | by hand in the console (`docs/runbooks/tailnet-setup.md`). Verified in R.2: the credential of D10 cannot read or change it, and it is not widened for this |
| Node signing | on, per D4 | command line only; runbook |
| Edits in the web console | allowed. Blocking them would also block an emergency change from the phone | recorded choice |
| Automatic client updates | off; versions are pinned | OpenTofu and each client |

## Home and away

Tailscale accepts the route to pve1 only while away. If it did so at home, Windows would send traffic for pve1 through the tunnel, because that route is more specific than the default route. It would work, slowly, and pve1 would log the wrong source.

`scripts\node2\travel.ps1`, in an elevated PowerShell:

| Mode | What it does |
|---|---|
| `-Away`, before leaving, still at home | Checks that no operator session is open, that the management window is closed and that no firmware update is pending. Starts the container on pve1, per D12. Records whether the backup VM runs, shuts it down cleanly, and runs `pbs-vm.ps1 -Away`, which converges without the port forward. Checks the Windows firewall and the Tailscale preferences. Shows when the laptop's key expires. Connects Tailscale with the route accepted. Then proves the whole path: the container is online and signed, the route is approved, and one SSH command to pve1 arrives from 10.0.30.10 |
| `-Home`, back on the home network | Disconnects Tailscale. Stops the container on pve1 and pauses its health check, per D12. Runs `pbs-vm.ps1`, which restores the forward. Starts the backup VM only if it ran before `-Away` |

One script owns the forward and the firewall rules: `pbs-vm.ps1`. `travel.ps1` only calls it.

No mode is stored anywhere. The tooling asks pve1 which address it sees:

| Recipe | At home | Away: pve1 sees 10.0.30.10 |
|---|---|---|
| `just session-start` | as today | allowed; the session lasts 2 hours instead of 12; ending it also disconnects Tailscale |
| `just pve-apply --check`, other dry runs | allowed | allowed |
| `just pve-apply`, `pve-tokens`, `pve-backup-init`, `pve-bootstrap`, `pve-media` | allowed | refused by a first task in each play, and by the media script |
| `just tofu pve ...`, the cluster from Phase 5 | allowed | allowed |
| `just tofu remote plan` | allowed | allowed |
| `just tofu remote apply`, `destroy` and every other verb | allowed | refused by the wrapper |
| `just tofu tailscale ...` | allowed | allowed; the policy's own tests refuse a policy that cuts the laptop off |
| Container play, `openwrt-*`, `pbs-*`, `just luci` | allowed | not reachable |

At home with Tailscale left connected and the route accepted, the same guard refuses real runs and says why. The message is to disconnect.

While you are away, pve1 has no backup target. The backup server is a VM on the laptop. The dead-man's switch reports the missed runs. Backups are not sent through the tunnel.

## Steps

| # | Step | Needs the owner | Changes a device | Gate |
|---|---|---|---|---|
| R.0 | Records: this plan approved (done 2026-10-09); ADR 0005 (done 2026-10-09); fresh encrypted exports of the three network devices; zero differences on all devices. The rotation path for the state passphrase is rehearsed on the marker state (backlog B29, due before the first real state) | approval | No | Exports in the private repository; zero differences; a plan succeeds after the rotation. **Passed 2026-10-09:** exports taken; the router and both access points equal Git; the hypervisor's dry run shows no change on the host; a fresh host backup was taken; the rotation was rehearsed to a generated passphrase and back (`docs/runbooks/rotate-state-passphrase.md`) |
| R.1 | OpenTofu wrapper: credentials per root, so each root receives only its own. Proxmox provider pinned; the API token and the hypervisor's own CA certificate proven on the existing marker root, with no "insecure" switch. Provider lock files committed | - | No | A read through the token succeeds; a call outside its scope is refused; `just tofu-lint` passes in CI. **Passed 2026-10-09:** the provider read the API's version (9.2.2) and the token's pool with the certificate verified against the hypervisor's own CA; `just test-token` passed, 10 checks; a second plan shows no changes |
| R.2 | Tailnet: account by GitHub login; the allow-all default policy replaced at once by a policy that allows nothing, with deny tests; the settings of the table above; the OAuth client stored with `just secret-set`; OpenTofu root `tailscale` | login, OAuth client | Tailscale only | The plan is clean after apply; a test broken on purpose makes it fail; the client's scopes read back and recorded. **Passed 2026-10-09:** the two resources were imported and applied, and a second plan shows no changes. Read back through the same credential: no grant, one test, no device; device approval on, user approval on, key expiry 90 days, automatic updates off. The credential's scopes are `policy_file`, `feature_settings`, and the two the console adds, `devices:core:read` and `devices:posture_attributes`; creating an auth key with it is refused. A policy with a grant that the deny test forbids stops `just tofu tailscale plan` and `apply` with the test named. That needed a check of our own in the wrapper: the provider's plan passed with the failing test, and only Tailscale's save refused it ("400", the tailnet unchanged). Open at the gate: the owner switches the name service off in the console |
| R.3 | Laptop and phone: Tailscale client at the pinned version, preferences set by a script in Git, state encryption per D5, left disconnected; the phone enrolled. `pbs-vm.ps1` gains the `-Away` switch and a deny for the Tailscale address range on the backup VM's adapter. A policy pull request adds the laptop's address and the grant | phone | Workstation | From the phone, nothing on the laptop answers. State encryption confirmed, and the recovery after a simulated loss of the state recorded |
| R.4 | Node signing: the machine list holds exactly the laptop and the phone, and their keys match what each device shows; device approval off; signing enabled from the laptop as the only signer; disablement secrets stored. If signing cannot be enabled with one signer, the choice of a second signer returns to the owner and device approval stays on until then | secrets stored | Tailscale only | `tailscale lock status` shows it on with the laptop as signer; recovery with a disablement secret rehearsed once and signing enabled again |
| R.5 | Router: VLAN 30 on the bridge and on lan1, interface `remote`, zone `remote`, E15 to E17; VLAN 31 and its empty zone. One guarded apply from the wired workstation. The same pull request adds the rows to section 6 of the architecture | - | Router | The router confirms itself; zero differences; the new rules and the VLANs on lan1 read back. The zone `home_remote` has input and forward set to reject and appears in no service rule; its interface has no IPv6 address, route or advertisement. The rules are exercised in R.7, when a host exists in the zone |
| R.6 | Hypervisor, in two runs. First the access rule for the cluster VLAN is rewritten: the VLANs on the bridge and the VLANs the token may use become two separate lists. That run changes nothing, with the token's permissions read back before and after. Then VLANs 30 and 31 on the bridge through the guarded change; the firewall rows; a pool for the container; the token's rights for that pool and for VLAN 30; the template fetched and checked against a pinned checksum. The role learns to print the firewall file's difference in a dry run, because today a dry run shows nothing of it | - | pve1 | The printed difference reviewed before the real run; `pve-firewall compile` is clean; a second SSH login succeeds before the first is closed; second run changes nothing; the token's rights read back are exactly VLAN 50 and VLAN 30 |
| R.7 | Container: created by OpenTofu in a root of its own, unprivileged, protected against deletion, root's key and the resolver set, its VLAN tag validated as 30 in code and in CI. pve1's firewall is switched on for its network device: inbound E17 only; outbound name lookups at 10.0.30.1, E15 and E16; address filter on. The firewall is already on for pve1 as a whole, so this changes nothing for the host. Whether the token or the hypervisor role writes that file is decided here by what the token may do; if the token can write it, it can also remove it, and the layers table says so. Negative tests of the token. Then `just test-remote`, a new script, runs twice from inside the container, before the container has a filter of its own: with pve1's layer off, which proves the router alone, then with it on | - | pve1: one container | Apply, then a plan without changes. The same container without a VLAN tag, on VLAN 10 and on VLAN 31 is refused. From 10.0.30.10 exactly E15 and E16 answer. A second, temporary address in the zone is refused by pve1's firewall before it reaches the router, and with that layer switched off for the test, by the router and by pve1's host firewall. 10.0.50.201 on tcp 443 is refused, with the layer that refuses it named. The script also reads back that the firewall flag is set on the device. No IPv6 address, route or router advertisement in the zone |
| R.8 | Container configured: bootstrap play, then its role (operator account and keys, SSH on its own address only, the filter, security updates over HTTPS, Tailscale pinned, as an unprivileged user, in userspace mode, the route advertised, a timer that pings a healthchecks.io check). The owner logs the node in. It shows as locked out until it is signed from the laptop, connected at home without accepting routes. That is the test of node signing and its first rehearsal | login, signing | Container | Second run changes nothing; the route is approved by the policy alone; forwarding is off; `just test-remote` a third time, now with the container's filter; the container does not advertise an exit node, read back from the device; with a temporary grant to the container's tag, its SSH port does not answer over the tunnel; packet-size checks and a 100 MB copy from WSL pass |
| R.9 | Travel mode: `travel.ps1`; the guards of the table above; the short session while away | - | Workstation | At home the path is direct; away it is the tunnel; each refused recipe is refused; `just test-fences` passes at home with Tailscale disconnected and connected |
| R.10 | Tests from an outside network, and the drills | hotspot | No | See "Tests" |
| R.11 | Documentation: architecture, security and recovery documents; component document; runbooks for tailnet setup, container rebuild, key renewal while away, lost laptop and lost phone; secrets register; gate record `phase-r.md`. The lost-laptop drill per D11 | drill | No | Merged; the drill recorded before the laptop first travels with the tunnel |

Each step is its own pull request. R.5 and R.6 only add rules; no existing rule for the workstation is touched.

What closes the phase: R.0 to R.11 with their gates. The week of memory measurement stays open after the gate and does not hold up Phase 5.

## Tests

`just test-remote` is a new script beside `just test-fences`. It runs the allow and deny probes from inside the container through pve1.

| From | Must work | Must be refused |
|---|---|---|
| Laptop on a phone hotspot, `-Away`, dock and direct link unplugged | `ssh ops@10.0.10.10`; the web interface with TOTP, including a console window; `just pve-apply --check`; a 100 MB copy in each direction | Every other port on 10.0.10.10. A recipe from the refused list. The routes the laptop accepted are exactly the advertised ones: one here, more after the household plan |
| The same session, read on pve1 | The SSH log shows 10.0.30.10 as the source | - |
| The phone, which the policy does not name | - | 10.0.10.10 on any port; the laptop; the container |
| Inside the container, `just test-remote` | E15 and E16 | Any other port on pve1; the router's SSH; any address in the trusted, IoT, guest and servers networks; the internet on a port outside E16 |
| A second temporary address in 10.0.30.0/24 (R.7 only) | - | Everything: by pve1's firewall on the device first; with that layer off, by the router and by pve1's host firewall |
| Inside the container, each layer alone (R.7 and R.8) | E15 and E16 | The same deny list, shown once at the router with the other layers off, once at pve1's firewall, once at the container's filter |
| Laptop at home, `-Home` | Everything as before Phase R; `just test-fences`; the nightly backup | - |
| Any other device on the home networks | - | Any port on 10.0.30.10 |

A probe from the hotspot to a home address that is not advertised never leaves the hotspot's network and proves nothing about home. That is why the deny tests of the router's layer run from inside the container.

Drills, each done once and recorded:

1. **Lost laptop**, per D11. It also records what a removed laptop can do after it logs in again: whether it is locked out, and whether it can sign itself. That is not documented.
2. **Rebuild.** Destroy the container and create it again from Git, with the five steps of D9. Record the time.
3. **Outage.** Stop the container. The health check alerts, remote access is gone, and everything at home works as before.
4. **Speed.** Record whether the path is direct or relayed, the delay, and the time of a real dry run, with and without the UDP rows of D8.
5. **Memory.** Record the container's peak memory over a week, including one run of the security updates. Then set its limit.

## Lost laptop

Everything in the first block can be done from the phone's browser, in this order. It needs your GitHub login on the phone at that moment, with a second factor that is not the laptop.

1. Remove the container `remote1` from the tailnet. It can only come back through a login at home. This closes the administration path at once, whatever the laptop still holds.
2. GitHub: change the password, end every session, revoke the command-line token.
3. Remove the laptop from the tailnet. Then delete every device in the machine list except the phone and, once it exists, `home1`, and check in the console that the policy equals Git.
4. Revoke the OAuth client of D10.

If the machine list or the policy was changed by someone else, remove `home1` too. Household access then waits until you are home.

What stays valid until you are home: the laptop's signing key, the operator's SSH key and the stored secrets. After step 3 the laptop's signing key can still sign, but nobody can add a device without your GitHub login. With the path closed in step 1, the SSH key and the secrets reach the lab from nowhere outside.

At home: check that the machine list holds exactly the known devices, as in R.4; disable node signing with a disablement secret from the container's console and enable it again without the lost laptop; then `docs/runbooks/operator-key-compromised.md`, whose premise "a stolen SSH key needs a place in the home network" is corrected in R.11.

If the phone is lost: the household plan has the procedure. The phone holds no signing key.
## What is not possible remotely

- Anything physical: power, the boot menu, a hung host. pve1 has no remote console of its own.
- When pve1 or the container is down, remote access is down.
- Backups of pve1, the backup server, the router and the access points.
- Patching the container or the Tailscale version during a trip. Version changes are pull requests applied at home.

## Rollback and removal

| Situation | Action |
|---|---|
| A step fails its gate | Every step only adds. Revert its pull request and apply; the router and the hypervisor's bridge restore themselves if a change is not confirmed |
| Remote access must stop now | Remove the container from the tailnet in any browser, or stop it from pve1. The home path is unaffected |
| Phase R is removed for good | After the household path is removed: destroy the container with OpenTofu; revert the pull requests of R.5 and R.6; delete the tailnet. Nothing else depends on it |

## Secrets created in this phase

| Secret | What it can do | Where it lives | Rotation | Revoked by |
|---|---|---|---|---|
| OAuth client for the policy root | Change the policy and the settings | Private repository, SOPS | On suspicion, and yearly | The Tailscale console |
| Laptop: network key and signing key | Join as the laptop; sign devices | The laptop, sealed per D5 | Network key every 90 days per D7; signing key on loss | Removing the device; the signing key by disabling and enabling node signing |
| Phone: network key | Join as the phone | The phone | Every 90 days per D7 | Removing the device |
| Container: network key | Join as the tagged router. No expiry | The container, readable by root only; in no backup | With every rebuild | Removing the device |
| Disablement secrets, three | Switch node signing off for the whole network | Password manager and one printed copy. Never Git, never Tailscale support | Used once, then new ones | Not revocable; a used one is public |
| Health-check address of the container | Report "alive" | Private repository, SOPS | On suspicion | The healthchecks.io console |
| The existing Proxmox API token, first real use | Create and change guests in its pool and VLANs | Private repository, SOPS | As in the secrets register | `just pve-tokens` |

## Risks

| Risk | What limits it |
|---|---|
| The GitHub account is the root of trust for the tailnet, and Tailscale cannot check its second factor | Two-factor login and recovery codes are a stated precondition, checked before the gate. With node signing, a takeover alone cannot add a device. The router's rules bound whatever a changed policy would allow |
| Node signing does not protect the policy. Whoever controls the account can widen it among the signed devices | The signed devices are the laptop, the phone and the container. The laptop accepts nothing inbound, and no grant names the phone as a destination. The container's filter and the router's rule E15 do not move |
| The laptop leaves the house with a network key, a signing key and, while a session is open, the SSH key and the decrypted secrets in memory | D5; a session of 2 hours while away, which also ends the tunnel; `-Away` refuses to start with a session open; the lost-laptop procedure closes the path from the phone in one step |
| The container can reach any internet host on tcp 443. A compromise of it is a standing foothold | It is bounded by the router's rule E15, by pve1's own logins, and by the health check going silent if it is stopped. It holds no secret of the lab |
| The container's network key does not expire. That is the vendor default for a tagged device | Not backed up; readable by root only; the policy gives its tag no rights. Recorded as exception X27 |
| Every remote session reaches pve1 from one address, and the free plan keeps no traffic logs. After an incident, traffic cannot be attributed to a device | One person uses it. pve1 logs each login. Recorded as exception X29 |
| Userspace mode is rated slower and newer than kernel mode by the vendor | Tested in R.8 and R.10 before the gate. If it fails, the choice between a kernel-mode container, which needs one root-run step on pve1, and a small VM returns to the owner |
| Both ends sit behind provider NAT, so traffic is probably relayed | Usable for SSH and Ansible, slow for large copies. Measured in the speed drill. A relay of your own is a job for the later cloud server |
| The container dies or loses its signature while you are away | The health check alerts through the existing channel. `-Away` proves the whole path before you leave. Nothing repairs it remotely |
| An access-rule trap in the hypervisor play: the cluster VLAN is addressed as "the first guest VLAN", so adding VLAN 30 in front would move the token's right and delete the old one | R.6 rewrites the rule first, in a run that must change nothing, and reads the permissions back |
| The hypervisor's firewall has no automatic revert, and a dry run shows nothing of it today | R.6 adds the printed difference; the change adds rows only; a second login is opened before the first is closed; done at home with the console in reach |
| The first guest is created before the three checks on guest network tags that the architecture plans for Phase 5 | The token's own scope refuses a wrong tag, proven by the negative tests; R.7 adds the validation and the CI test; the drift job stays a dated open item |
| The free plan is for non-commercial use, and its limits can change | Checked again before each phase that depends on it. Nothing at home depends on Tailscale |
| A tailnet created with a GitHub login cannot move to another identity provider later | Recorded in ADR 0005. A change means enrolling every device again |

## Corrections to the approved design

| The design says | Finding of 2026-10-08 | The plan does |
|---|---|---|
| Node signing and device approval | The two cannot be on together | Device approval until signing is enabled, then signing only |
| A GitHub identity with two-factor login | Tailscale cannot require or verify it | A precondition the owner confirms, with a check before the gate |
| Key expiry | Tagged devices have no expiry by default | Expiry on the owner's devices; the container is exception X27 |
| A container of 128 MiB | No published figure for the client's memory; updates are the peak | 256 MiB as a ceiling, measured, then lowered |
| A container as a subnet router | Proxmox lets only its root login hand a tunnel device to a container | Userspace mode, which needs none |
| Remote access reaches the targets of E1 to E3 | The owner decides per target, D1 | pve1 only in this phase |
| VLAN 30 has no router address | A zone needs one | 10.0.30.1 |
| Nothing readable is stored on the workstation (X23) | The laptop now holds a network key and a signing key | X23 reworded, with D5 |

New numbers: firewall exceptions E15 to E17; exceptions X27 (the container's key without expiry), X28 (remote administration depends on Tailscale and GitHub) and X29 (no attribution per device, no traffic logs).

Backlog items this phase touches:

| Item | Proposal |
|---|---|
| B20, key-bound operator access by a tunnel on the router | Closed in ADR 0005: the provider's NAT rules it out for remote access, and at home the two pinned addresses stay |
| B29, rotation path for the state passphrase | Done in R.0 |
| B30, rehearsal of the lost-workstation runbooks | D11 |
| B31, negative test of the OpenTofu token | Done in R.1 and R.7 |
| B33, the backup VM's unrestricted outbound traffic, due with the next change to `pbs-vm.ps1` | Stays a recorded exception, moved to the monitoring phase. R.3 only adds the deny for the Tailscale range |
| New: the cloud server as an outside monitoring viewpoint and as a relay | Later add-on, own plan |

## Cost on Node 1

| Line | GiB |
|---|---|
| Visible to Linux, measured | 15.54 |
| Host in use without guests, measured | 1.85 |
| Planned guests of Phase 5 and their overhead | 11.90 |
| Container, as a ceiling | 0.25 |
| Left | 1.54 |

The standing gate is 1.5 GiB. A container's memory is a limit, not a reservation, so its real use is lower; it is measured in the memory drill. If the measured peak leaves less than 1.5 GiB with the planned guests, the limit is lowered or the worker shrinks by the difference.

Disk: 4 GiB thin for the container, about 130 MiB for the template on the root disk.

## Versions

| Piece | Pin |
|---|---|
| Tailscale client, laptop and container | 1.102.5, released 2026-10-05. 1.104.1 followed on 2026-10-07 and moves in by pull request after a week without reports |
| Tailscale provider | 0.29.2 |
| Proxmox provider | 0.116.0 |
| Container template | Debian 13 standard 13.6-1, by name and checksum |

Every bump is a pull request, applied at home. Automatic updates are off on the laptop, in the container and in the tailnet.

## To verify in the lab during the build

These could not be settled from documentation. Each is checked in the step named, and a failure there stops the step.

| Check | Step |
|---|---|
| The provider works under OpenTofu 1.13 with state encryption enforced | R.1 |
| The policy field that routes through the container is accepted on the free plan; if not, the grants are written without it | R.2. Checked 2026-10-09: a policy with a tag owner and a grant through that tag passes Tailscale's validation. That it also routes is R.8's check |
| The two scopes are enough for the policy and the settings; how the name service is switched off | R.2. Checked 2026-10-09: enough. The name service is switched off by hand in the console |
| The Tailscale command line can be driven from a script, and which calls need an elevated prompt | R.3 |
| State encryption on the pinned version, and what a lost state costs | R.3 |
| The token can create an unprivileged container on VLAN 30 and nothing wider; the template has an SSH server and Python | R.7 |
| Userspace mode works as an unprivileged user and carries SSH, the web console and an Ansible run; pve1 sees 10.0.30.10 | R.8 |
| A single-host route is advertised and approved by the policy alone; a grant through the container is enough without a grant to it | R.8 |
| WSL reaches the tunnel through Windows without stalls from the smaller packet size. Userspace mode has no place for a fix on the container, so the fallback is a smaller packet size inside WSL, kept in Git | R.8 |
| The security updates leave the pinned Tailscale package alone | R.8 |
| Node signing can be enabled from the command line with one signer, and recovery with a disablement secret works | R.4 |
| pve1's firewall on a container's network device stops a foreign source address on the VLAN-aware bridge, and who may switch it on: the token or the hypervisor role. If it cannot be set as described, the administration path goes on with three layers, since VLAN 30 holds one guest and the router's zone still separates, and the household plan waits for a decision | R.7 |
| What a removed laptop can do after logging in again | drill 1 |

## Checked on 2026-10-08

- Tailscale: [subnet routers](https://tailscale.com/kb/1019/subnets), [kernel and userspace routers](https://tailscale.com/kb/1177/kernel-vs-userspace-routers), [firewall ports](https://tailscale.com/kb/1082/firewall-ports), [tailnet lock](https://tailscale.com/kb/1226/tailnet-lock), [grants](https://tailscale.com/docs/reference/syntax/grants), [policy file](https://tailscale.com/docs/reference/syntax/policy-file), [key expiry](https://tailscale.com/docs/features/access-control/key-expiry), [unprivileged LXC](https://tailscale.com/kb/1130/lxc-unprivileged), [package index](https://pkgs.tailscale.com/stable/).
- Proxmox: the permission checks for containers in [pve-container](https://git.proxmox.com/?p=pve-container.git), read on the master branch; confirmed against the installed version in R.6.
- The pages were read through a summarising tool. Every command and flag is read again on the pinned version before it goes into a role or a runbook.
