# ADR-0005: Administrative access at home, and access from outside the house

- Status: Accepted by the owner on 2026-10-09 (all recommended defaults of both plans)
- Date: 2026-10-09
- Deciders: repository owner
- Supersedes: none. It completes decision 9 of `../ARCHITECTURE.md` section 19 and answers question Q13 of section 20. It closes backlog item B20.

## Context

Since Phase 2 the lab is administered from one workstation, admitted by its two pinned home addresses (exceptions E1 to E3). Nothing is reachable from outside the house. That was deliberate, and remote access was left as an optional phase.

On 2026-10-08 the owner asked to work on the lab from mobile data and public Wi-Fi. On 2026-10-09 the owner widened that: from away, on the laptop and the phone, the home should also be usable. That means IoT devices now, the services hosted on Node 1 later, browsing through the home connection, and a way to lock things down when something looks wrong.

Four facts bound the choice:

1. **No inbound connectivity.** The provider uses carrier-grade NAT and no IPv6. A VPN server at home cannot be reached. Both ends must connect outwards and meet at a third party.
2. **The home network grants nothing by position.** Every rule names one device and one port. A design that makes a remote device "at home" would undo that.
3. **The laptop's disk is not encrypted** (exception X23), and the laptop is the device that travels.
4. **One operator.** Whatever is built has to be understood, kept in Git and repaired by one person.

The research is in `../research/2026-10-08-remote-access-research.md` and `../research/2026-10-09-household-access-research.md`. The plans are `../phases/phase-r-plan.md` and `../phases/phase-r-household-plan.md`.

## Decision drivers

- No program that faces the internet runs on the device that enforces the segmentation.
- At least one layer of every restriction must be out of reach of the tunnel provider and of anyone who takes over the account used to sign in.
- Two purposes get two paths with different rights. Administration and household use never share an address at home.
- Closing must be possible from anywhere. Opening must need presence at home.
- At home, nothing changes and nothing depends on a service outside the house.
- The fewest moving parts that meet the above.

## Decision

**At home: unchanged.** The workstation's two pinned addresses and the exceptions E1 to E3 stay the only way in.

**From away: Tailscale, with two small containers on Node 1, each in a network of its own.**

| | Administration path | Household path |
|---|---|---|
| Clients | The laptop | The laptop and the phone |
| Home endpoint | `remote1`, VLAN 30, 10.0.30.10 | `home1`, VLAN 31, 10.0.31.10 |
| Reaches | pve1: SSH and the web interface | Named devices and ports; the internet for web traffic |
| Built | First | After the first has passed its gate |

Each container runs Tailscale as an unprivileged user in userspace mode and relays connections; it does not route packets. The targets see the container's address, never the workstation's. Each path is held by the Tailscale policy, the container's own filter, pve1's firewall on the container's network device, and the router's rules for its zone. The router's rules are the layer that Tailscale and an account takeover cannot change.

Further decisions, each with its reasons in the plans:

- **Identity:** the owner's GitHub login. Tailscale cannot verify its second factor, so that is a precondition the owner keeps.
- **Node signing is on**, with the laptop as the only signer. An Android phone cannot sign. Device approval cannot be on together with node signing and is switched off when signing is enabled.
- **The administration container runs only while the laptop is away.** A script on the workstation starts it before a trip and stops it afterwards.
- **Tailscale accepts the home route only while away.** At home it would take over the path to pve1.
- **What may be changed from away is limited by the tooling**: cluster work and dry runs are allowed; real changes to pve1's own configuration, the install media and the containers are refused. The router, the access points and the backup server are not reachable at all.
- **The policy, its tests and the tailnet settings are code**, applied from the workstation through a second OpenTofu root with a credential limited to the policy and the settings.
- **A lockdown switch** works one way: its levels are files in Git, the router fetches the signal and applies them itself, and reopening happens at home.
- **The phone can complete the GitHub login** behind two app locks. This is accepted as exception X32, with a separate PIN on each app, no standing session on the phone, and printed recovery codes at home. Two hardware keys remain the stronger alternative (backlog B8).

## Alternatives considered

| Alternative | Why not |
|---|---|
| Tailscale on the router | The exposed program would run on the device that enforces every firewall rule. The package barely fits the flash and lags upstream. Its one advantage, access while pve1 is down, buys little: pve1 has no remote console |
| A VPN that makes the remote device "at home" | It needs a rented public server because of the NAT, and it turns position into rights: one stolen, unlocked laptop would hold the whole house, the router included |
| A tunnel on the router with a key instead of an address (backlog B20) | The NAT rules it out for access from away. At home the two pinned addresses work and stay. B20 is closed |
| Tailscale on the hypervisor itself | A third-party program as root on the hypervisor, and its traffic would arrive inside the tunnel, past the router's firewall |
| One container for both purposes, or two addresses in one network | Two guests in one network reach each other without passing the router and can take each other's address. The router could no longer tell the paths apart |
| The household container inside the trusted network | No new rule would be needed. A remotely reachable machine would then sit beside every family device and could imitate the workstation's addresses while the laptop travels |
| A kernel-mode subnet router in a container | Proxmox lets only its root login hand a tunnel device to a container. Automation uses a scoped token and never the root login |
| The router's own web interface from away, even read-only | Its permission layer had several bypasses in 2026, a broad read right includes the Wi-Fi keys, and it would put the router's password prompt on a network address |
| A cloud server as the meeting point now | A public machine to patch and watch, and a free one can be taken back when idle. It is kept as a later add-on: a relay for speed, and a fast exit node |

## Consequences

- Remote access depends on Tailscale and on GitHub. Nothing at home depends on either.
- A tailnet created with a GitHub login cannot move to another identity provider later. A change means enrolling every device again.
- When pve1 or a container is down, that path is down, and nothing repairs it from away.
- While the laptop is away, pve1 has no backup target, because the backup server is a VM on the laptop.
- Both ends sit behind provider NAT, so traffic is relayed through Tailscale's servers. That is fine for SSH and for operating a device, slow for large copies and for browsing through home.
- A new target needs a visit home: the container that offers it takes changes only from the home addresses.
- Every remote session reaches a target from one address per path. The targets cannot tell remote devices apart, and the free plan keeps no traffic logs.
- New exceptions: X27 (the containers' network keys do not expire), X28 (dependence on Tailscale and GitHub), X29 (no attribution per device), X30 (no record of which device used the home connection), X31 (the phone as a device with standing access; targets without a login), X32 (the phone can complete the GitHub login). They are written into section 15 with the steps that create them.

## What this changes in the approved design

| The design said | Now |
|---|---|
| Remote administration is an optional phase limited to the targets of E1 to E3 | Two paths with their own targets, in two zones |
| Node signing and device approval together | Node signing; device approval only until it is enabled |
| A GitHub identity with two-factor login as a property of the system | A precondition the owner keeps |
| Key expiry on every device | On the owner's devices; the containers are exception X27 |
| One container of 128 MiB | Two, each with a ceiling of 256 MiB, measured and then lowered |
| VLAN 30 reserved, without a router address | VLAN 30 and VLAN 31, each with a router address and a zone |
| Nothing readable is stored on the workstation (X23) | The laptop also holds a network key and a signing key, sealed to its TPM |
