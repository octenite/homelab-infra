# Phase R, second part: household access from away

Status: **proposed on 2026-10-09; not approved, nothing built.** On 2026-10-09 the owner widened the purpose of remote access: it is also for using the home from away, on the laptop and the phone, not only for building the lab. This plan covers that. The administration path is `phase-r-plan.md`; the changes this plan makes there are listed at the end. The research is in `docs/research/2026-10-09-household-access-research.md`. The draft was reviewed by two independent reviewers; their findings are worked in.

Goal: from away, the owner can operate chosen home devices, later the services hosted on Node 1, and can browse through the home connection. The owner can also close things down from away when something looks wrong. None of this may reach the management side.

It is built after the administration path has passed its gate, and reuses what that phase proves: the container form, the token, the policy root, node signing. The planning of the step after Phase R does not wait for this gate.

Answers the owner gave on 2026-10-09, used below: the phone is an Android phone; GitHub has two-factor login and recovery codes; the targets are mainly IoT devices now, with three or four more ESP32 devices for lights, relays and sensors to come, and services hosted on Node 1 later; family members come later, as users only; for the router, looking is enough, and a way to lock down from away is wanted; applications come before the platform when the next step is planned, and no approved plan is altered until then.

## Two paths

| | Administration path | Household path |
|---|---|---|
| For | Building and running the lab | Using the home from away |
| Clients | The laptop | The laptop and the phone |
| Home endpoint | Container `remote1`, VLAN 30, 10.0.30.10 | Container `home1`, VLAN 31, 10.0.31.10 |
| Reaches | pve1: SSH and the web interface | Named devices and ports; the internet |
| Never reaches | Household devices | pve1's management ports, the router's login, the access points, the cluster's API, the admin listener, the workstation's addresses |

Why a second container in a second network, and not a second address beside the first: two guests in one network can talk to each other without passing the router, and one can take the other's address. The router and pve1 trust 10.0.30.10 by address. Only a network of its own makes the difference visible to the router, the one layer that nobody at Tailscale and nobody holding the account can change.

The layers, and what each holds against:

| Layer | Holds against |
|---|---|
| Tailscale policy: every grant names a device as its source and one container's tag as its way | a mistake on a client |
| The container's own filter | a policy widened by mistake or by an account takeover |
| pve1's firewall on the container's network device, with the address filter | a compromised container: root inside it cannot remove this layer or take another address |
| The router's rules for the zone of VLAN 31 | all of the above |
| Each target's own login | whoever gets through. A printer usually has none |

In the container's filter, in pve1's list and in the router's rule, "internet" means every address outside the private ranges 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 and 100.64.0.0/10. So the rule for web traffic admits no home address and none of the provider's equipment in front of the router.

Four things rest on the Tailscale side alone, because both containers see only the tunnel:

1. The phone never uses the administration container. Behind it stand only pve1's own logins. This is the reason for decisions H4 and D12.
2. Nothing reaches the phone. A phone cannot refuse inbound connections by itself.
3. The phone takes no name service from Tailscale. Whoever takes the account could set one.
4. The administration container is not an exit node. The router cannot help here, because that container may reach the internet on tcp 443.

None of the four leads to the management side by itself. The policy that holds them can be rewritten from any device on which your GitHub login is open.

## What you get, and when

| You want | Available | Note |
|---|---|---|
| The IoT devices you name, by address | At the gate of this plan | The ESP32 first. Each further device needs a reserved address and one more row in five places. With three or four more ESP32 devices coming, that is the practical reason to put Home Assistant in front early: one address and one login for all of them |
| Browsing through the home connection | At the gate of this plan | At relay speed. See "Speed" |
| A lockdown switch | At the gate of this plan | Decision H8 |
| An alert when an unknown device joins the home network | At the gate of this plan | To the existing Telegram channel. It is the early way to notice something |
| Services hosted on Node 1, Home Assistant among them | When each exists | They sit behind one address, the household listener. One rule serves them all |
| A view of the home network | Not before Phase 11 | Decision H3 |
| Family devices on the home network | Not through a route | Decision H6 |
| Family members with their own access | Later, as invited users with one grant to the hosted services | No decision needed now. The free plan allows six users |

Whether a hosted service is also published on the internet is decided per service, when it is built. The default is private, through this path. Public is for a service that someone without Tailscale must reach, through the design's separate public edge with a login in front. A password manager and every admin page stay private.

## Decisions needed from the owner

| # | Decision | Recommended | Alternatives, and the honest cost of each |
|---|---|---|---|
| H1 | What the household path reaches at home | Named devices and ports only. Now: the ESP32's page; the printer once its model and ports are known. Later: the household listener; the direct device rows are then removed, so every remote action passes a login. Never the workstation's addresses, never the router | The whole IoT and trusted networks, as a phone on the home Wi-Fi has. Less to maintain. A lost, unlocked phone then operates every device that has no login, and a remote path reaches the network in which the workstation's trusted addresses can be imitated while the laptop travels |
| H2 | Browsing through the home connection | Yes, on the household container only, for web traffic: name lookups, tcp 80 and 443, udp 443. Wider only when something you use fails. Costs: this container can reach any web server, so "reaches only X" is true of the administration container alone; whatever is done through it leaves under your home connection's name, with no log of which device did it; it is slow until a relay of your own exists | No exit node: the household container keeps a narrow outbound rule. Or all ports: everything works, and the router no longer narrows anything for this container |
| H3 | Seeing the home network from away | Nothing on the household path now. LuCI stays where it is: at home, inside an SSH session. Decided now in principle only: a viewer-only view of the home network may later be published on the household listener. Its form is designed in the phase that builds it, not before Phase 11, when single sign-on with a second factor exists. Condition fixed today: no login page of an admin application is ever served there | A read-only LuCI login: the mechanism exists, but its own tool calls itself experimental, its permission layer had several bypasses in 2026, a broad read right includes the Wi-Fi keys, and it puts the router's password prompt on a network address. Or the router's SSH through the administration path, on the laptop only: the alternative in D1 of the administration plan |
| H4 | What the phone may hold | Node signing is decided as D4 of the administration plan: an Android phone cannot sign. Here the question is your GitHub login. Recommended: the phone holds no standing GitHub or Tailscale console session and is not the approver of the GitHub second factor. The second factor works without the phone and without the laptop: a hardware key, or printed recovery codes carried apart from both. The console is opened on the phone only in an emergency and closed afterwards | A standing session on the phone, recorded as an exception. A stolen, unlocked phone can then rewrite the policy and stands at pve1's login pages, where only pve1's own password and second factor remain |
| H5 | When Home Assistant and the other services arrive | Decided when the step after Phase R is planned. See "Hosted services" | - |
| H6 | Family devices | Not reached through this path. The home network's address range is the commonest on hotel and public networks, so a route into it would send traffic to a stranger's device there. If one device matters, Tailscale is installed on that device and it gets its own grant | Routes for single family devices: a reservation and a rule per device, and it still collides on a foreign network that uses the same address |
| H7 | Speed | Build it, measure it, then decide on the cloud server. See "Speed" | Plan the cloud server now as the next add-on |
| H8 | A lockdown switch from away | Yes, as a one-way switch. Closing works from anywhere; reopening only at home. The levels are fixed in Git and the router applies them itself. See "Lockdown" | None: closing remote access through the Tailscale console exists in any case. Or remote control of the router: that is full control of the firewall from away, which the administration plan refuses |
| H9 | Form of `home1` | An unprivileged container, like `remote1`. It costs little memory. It shares pve1's kernel while it carries arbitrary web traffic for the exit node, so an escape from it would be root on pve1 | A small VM: its own kernel, about 0.4 GiB more memory. Or no exit node under H2: the container then carries far less |

## Needed from the owner

| Item | When | Why |
|---|---|---|
| Each new IoT device, when it is added: its name, and whether you need its own page from away | as they come | H1 is a list of names and ports. Known today: one ESP32 and the printer; three or four more ESP32 devices are planned |
| Where your GitHub second factor lives; whether GitHub or your password manager is open on the phone; whether you own a hardware key | with the approval | H4. Backlog item B8, two hardware keys, is the clean answer |
| Where pve1's second factor lives | with the approval | It is what stands behind the policy for the phone |
| A password on the ESP32's web page, web update off | before H.3 | See the risk on that password |
| The printer's model, and whether its page has a password | before its row is written | Its ports are read off the device, not guessed |

## Addresses and rules

| Item | Value |
|---|---|
| VLAN 31, zone `home_remote` | 10.0.31.0/24, router 10.0.31.1, no DHCP, no IPv6. Laid in steps R.5 and R.6 of the administration plan with its interface and nothing else, so this plan changes the router's firewall file only and the house network is not interrupted a second time |
| Container `home1` | 10.0.31.10, static; name lookups at 10.0.31.1 |

New firewall exceptions on the router:

| ID | From | To | Ports | Written |
|---|---|---|---|---|
| E18 | 10.0.31.10 | ESP32 10.0.60.10 | tcp 80 | H.3 |
| E19 | 10.0.31.10 | printer 10.0.60.182 | the ports read off the device | when its model is known |
| E20 | 10.0.31.10 | household listener 10.0.50.200 | tcp 443 | in the phase that builds and proves the listener |
| E21 | 10.0.31.10 | internet, as defined above | tcp 80, 443 and udp 443 per H2; what Tailscale itself needs | H.3 |
| E22 | workstation 192.168.1.196, .197 | 10.0.31.10 | tcp 22: configuring the container, from home only | H.3 |

The zone also gets name lookups at the router, and the house's forced name lookups are extended to it. No rule leads from this zone to the management, trusted or guest networks, to any router login, or to the zone of VLAN 30. No rule leads into it except E22.

A later target, such as E20, is one pull request that touches five places: the router's rule, pve1's list, the container's filter, the route the container advertises, and the policy. The container part is applied at home.

pve1's firewall on the network device of `home1`: inbound E22 only; outbound name lookups at 10.0.31.1 and the E rows that exist; address filter on. The firewall is already switched on for pve1 as a whole, so this changes nothing for the host.

Tailscale policy, added to the one in Git:

- A second tag for `home1`. Each host route belongs to exactly one tag. Only the household tag may be an exit node.
- The laptop and the phone, named by their own tailnet addresses, may reach the household targets and the internet through the household tag. The phone has no grant through the administration tag.
- No grant names a phone, or either container, as a destination.
- Tests assert, among others: the phone cannot reach 10.0.10.10; nothing reaches either container; the administration tag cannot be used as an exit node; a device of the owner's login that no grant names reaches nothing.

## On the phone and the laptop

| Device | Setting |
|---|---|
| Phone | Routes on; exit node off unless wanted, because the exit node is what drains the battery. Android has no supported automatic switch for the home Wi-Fi: you toggle Tailscale, or accept that at home it takes the slow detour through the tunnel |
| Phone | Tailscale's name service off, set on the device. If the Android client offers no such switch, that is recorded |
| Phone | Key expiry of 90 days, as for the laptop. A screen lock is assumed. The client's version is whatever the store offers: recorded at each test, not pinned |
| Laptop | Uses the household path through `travel.ps1 -Away`, like the administration path. Browsing through home and an administration session probably cannot run at the same time: an active exit node is reported to cut WSL off. Tested in H.5; until it passes, the rule is one or the other |

An exit node gives the internet only. On the code read, its own filter drops traffic to private address ranges; this is tested on the pinned version in H.6. The plan does not rely on it: whatever the container forwards, the router admits only the rows above.

## Lockdown

You asked for a way to shut things from away when something looks wrong. The conditions, fixed with this plan:

- **One-way.** Closing works from anywhere. Reopening works only at home, by applying Git.
- **Levels fixed in advance, in Git.** The router applies them itself. Nobody gets a login on the router from away, and nothing new listens at home.
- **The family's internet stays up at every level.** A false alarm during a trip must not cut the house off.
- **The signal is authenticated**, and anyone who can send it can only close, never open.

| Level | Closes |
|---|---|
| 1 | All remote access: both containers are removed from the tailnet. This needs nothing new; it works from any browser today |
| 2 | Also: the IoT and guest networks lose the internet, and the paths from the trusted network to the IoT network close |
| 3 | Also: pve1 and everything on it is isolated from the other networks and from the internet |

For levels 2 and 3 the router has to learn of the signal without anyone connecting to it. The candidate is a command to the existing Telegram bot, which the router fetches itself and accepts only from your account. It is chosen in step H.4 after it is verified; the alternative is a record in your own DNS zone that the router reads.

The switch needs something to notice with. From this plan on, the router sends an alert to the Telegram channel when a device that it does not know joins a home network.

## Speed

Both ends sit behind provider NAT, so traffic is relayed through Tailscale's servers. The nearest relay region is Bengaluru, with a single server. Tailscale publishes no rate for its relays. Its one published measurement, from Delhi to the United States, is about 2 Mbit/s relayed against about 28 Mbit/s through a relay of one's own.

So: operating a device or a service page will work. Browsing through home may be too slow to enjoy. The remedy is the later cloud server with a public address, which can be a relay for both paths and a second, fast exit node for privacy on public Wi-Fi. Nothing behind provider NAT can be such a relay. The free plan includes this feature.

## Hosted services

The services you named, Home Assistant first, are applications. The approved roadmap places applications in Phase 14, after the whole platform. On 2026-10-09 you said you prefer applications first and the platform as you learn, and that no approved plan is altered until the next step is planned. So this is recorded here and decided there. The options for Home Assistant, in one kind of figure, the memory left for other applications after the 10 % reserve the design always keeps:

| Option | When usable | Left for other applications | What it costs |
|---|---|---|---|
| In the cluster, as designed | Phase 14 | about 1.7 to 1.9 GiB | Nothing you can touch for many phases |
| Its own VM, the vendor's appliance, 2.2 GiB fixed | Soon after this plan | with the approved two-VM cluster: tight in Phase 11, does not fit from Phase 12. With a single-VM cluster: about 1.5 GiB | It updates itself outside Git. The single-VM shape reverses a recorded decision: every upgrade is then a full outage, and an application can starve the cluster's API |
| Its own container, about 1 GiB as a ceiling | Soon after this plan | about 0.8 GiB with the two-VM cluster | No add-ons. Probably needs a container feature that only pve1's root login may set |

Plex, photo and video backup and a shared drive need bulk storage. Node 1 has one 240 GB disk. That is a hardware question for the same step.

## Steps

| # | Step | Needs the owner | Changes a device | Gate |
|---|---|---|---|---|
| H.0 | This plan approved; ADR 0005 widened to household access; the list of H1; the answers of H4; the ESP32's page protected; its real ports probed from a trusted device | list, answers, ESP32 | ESP32 | The page asks for its password |
| H.1 | pve1: the token's row for VLAN 31. Container `home1` created by OpenTofu in the root of `remote1`, with pve1's firewall on its network device as stated above | - | pve1 | The plan shows `remote1` unchanged. The tag check accepts 30 for `remote1` and 31 for `home1` only. From `home1`, a second address and the address of `remote1` are refused at pve1 |
| H.2 | Policy, first part: the second tag, the automatic approval of its routes and of the exit node, the deny tests | - | Tailscale only | The tests pass; a grant widened on purpose is refused by them |
| H.3 | Router: name lookups for the zone, the forced lookups extended to it, E18, E21, E22. The firewall file only. Then `just test-remote` for `home1`, first with pve1's layer off, then with it on | - | Router | Zero differences; the listed pairs and name lookups at 10.0.31.1 answer; 10.0.50.201 on tcp 443 and the provider's equipment are refused, with the layer that refuses each named |
| H.4 | Lockdown: the mechanism verified and chosen; the levels as files in Git; the alert for unknown devices | choice | Router | Level 2 triggered from the phone on mobile data closes what the table says and leaves the family's internet up; reopened at home by applying Git; an unknown test device raises the alert |
| H.5 | Container configured with the role of `remote1` and its own values. Logged in by the owner; signed from the laptop, connected at home without accepting routes. Then the policy's second part: the grants for laptop and phone. Phone and laptop settings; the test of browsing through home beside WSL | login, signing, phone | Container, phone, workstation | Second run changes nothing; routes and exit node approved by the policy alone; `home1` and `remote1` each advertise only their own |
| H.6 | Tests and drills | hotspot | No | See "Tests" |
| H.7 | Documentation: architecture sections 4, 6, 7, 15 and 16; component document; runbook for a lost phone and for the lockdown; secrets register; gate record | - | No | Merged |

The household notices nothing in any step.

## Tests

| From | Must work | Must be refused |
|---|---|---|
| Phone on mobile data | The ESP32's page; with the exit node on, a web page shows the home connection's address | pve1 on any port; either container; the router; any home address that is not listed |
| Laptop away, `-Away` | The same, and the administration path as before | The same, except what the administration path allows. The routes the laptop accepted are exactly the advertised ones of both containers |
| Inside `home1`, each layer alone and then together | The rows that exist | pve1's management ports; 10.0.30.10; the router's SSH; the access points; the trusted network; 10.0.50.201 on tcp 443; the provider's equipment |
| Inside `home1`, with the policy widened on purpose | - | The same list |
| Inside `home1`, using the address of `remote1` or of the workstation | - | Everything, at pve1 |
| Through the exit node, with the policy widened on purpose | - | Any private address |
| A device of the owner's login that no grant names, as a policy test | - | Everything |
| The phone's shortcuts, on a foreign network with Tailscale off | - | They do not send the ESP32's password to whatever holds that address there |
| Phone at home | Home devices as before | - |

Drills, each done once and recorded:

1. **Lost phone**, by the procedure below. It records how long each step takes, whether the removed phone can join again, and whether a console session that was open on it is still valid.
2. **Lockdown**, as in H.4, from the phone and from the laptop.
3. **Speed.** Relay region, delay and real throughput, for a device page and for browsing.
4. **Memory.** The household container's peak while a phone browses through it.

## Lost phone

In this order, from the laptop or any browser:

1. GitHub: change the password, end every session, remove the phone as a second-factor device. GitHub is the root of trust; closing it first means the following steps cannot be undone from the phone.
2. Remove the phone from the tailnet.
3. In the console, the machine list holds only the known devices. `just tofu tailscale plan` shows no difference; if it does, apply Git.
4. If your password manager was open on the phone: remove that device in the manager, then treat what it held for the lab as exposed and replace it at home: the recovery SSH key, the disablement secrets, pve1's passwords.
5. Change the password of the ESP32's page and of each hosted service; pve1's second factor if its app was on the phone.

What else must be undone depends on what the phone held; that is why H4 asks.

## Rollback and removal

| Situation | Action |
|---|---|
| A step fails its gate | Every step only adds. Revert its pull request and apply |
| Household access must stop now | Remove `home1` from the tailnet in any browser. The administration path and the home are unaffected |
| The household path is removed for good | Destroy `home1` with OpenTofu; revert H.2 to H.5; remove the phone's and the laptop's grants. VLAN 31 stays laid, empty |

## Secrets created in this plan

| Secret | What it can do | Where it lives | Revoked by |
|---|---|---|---|
| `home1`: network key | Join as the household router. No expiry | The container, readable by root only; in no backup | Removing the device; rotated by a rebuild |
| Phone: network key | Reach what its grant names | The phone | Removing the device; expires every 90 days |
| Health-check address of `home1` | Report "alive" | Private repository, SOPS | The healthchecks.io console |
| Password of the ESP32's page | Operate the device | The device's configuration in the private repository; the phone's shortcuts | Changing it on the device |
| Lockdown signal | Close levels 2 and 3. It cannot open anything | Depends on the mechanism chosen in H.4; recorded there | Recorded there |

## Risks

| Risk | What limits it |
|---|---|
| The phone becomes a device with standing access to the home. Unlocked and stolen, it operates what its grant names | H1 keeps the list short. One step removes the phone, after GitHub is closed |
| Only the Tailscale policy keeps the phone off the administration container, and the policy can be rewritten from any device with your GitHub login open | H4; D12 of the administration plan, under which `remote1` runs only while the laptop travels; pve1's own password and second factor. If your password manager and your second-factor app are both on the phone, a stolen unlocked phone holds both |
| The ESP32's password protects against other devices at home, not against the phone that stores it; `home1` sees it in passing, because the page is not encrypted | What bounds the damage is that the page offers only its switches, with web update off, and that the lost-phone procedure changes the password. H1 removes the direct row once a service with a real login stands in front |
| The household container can reach any web server and carries browsing in the clear where a page is unencrypted. Compromised, it sees every destination | It reaches no home address beyond its rows, at the router and at pve1; it holds no secret of the lab except that password in passing; its health check goes silent if it is stopped |
| Traffic through the exit node leaves under the home connection's name | Only your named devices may use it; tests assert that. No log shows which device it was: exception X30 |
| Two exposed containers share pve1's kernel. An escape from either is root on pve1 | Both run unprivileged, without a device, without forwarding. H9 offers the VM |
| A userspace exit node is rated "acceptable" and "new" by the vendor, and one report describes it failing to advertise from a container | Checked in H.5. If it fails, the exit node moves to the later cloud server or to a small VM at home, by your choice |
| The household listener will be reachable from away. That an admin page is not served there rests on a point the design still has to prove in Phase 10 | E20 is written only in the phase that proves it |
| A hosted service may skip its login for "trusted networks". If the container's address were ever listed there, the path from away would need no login | A rule for every service plan: that list never contains 10.0.31.10 or the proxy |
| Memory: two containers at their ceilings leave 1.29 GiB on Node 1 against the gate of 1.5 | See "Cost on Node 1" |
| At home with Tailscale left on, the phone sends traffic for home devices through the tunnel | Slower, not broken. You toggle it |
| The lockdown signal can be sent by whoever holds the phone or the account used for it | It can only close. Reopening needs presence at home |

## Cost on Node 1

| Line | GiB |
|---|---|
| Left after the administration plan, with the planned guests | 1.54 |
| `home1`, as a ceiling | 0.25 |
| Left | 1.29 |

The standing gate is 1.5 GiB. A container's memory is a limit, not a reservation; both containers are measured. The household container is not squeezed, because it carries the browsing. The administration container's limit is lowered first, then the cluster's VM gives the difference, about 0.1 to 0.25 GiB. Disk: 4 GiB thin.

Versions: `home1` runs the pins of the administration plan.

## Changes to the approved design

| The design says | This plan |
|---|---|
| Remote access is limited to the targets of E1 to E3 (section 6) | A second purpose with its own targets, in its own zone |
| One reserved network, VLAN 30, for remote access | VLAN 31 beside it; a row and a column for each zone in the matrix |
| The remote-access container costs 0.125 GiB (sections 4 and 16) | Two containers with a ceiling of 0.25 GiB each, measured |
| Applications reach the IoT network only from the servers network | The household container reaches named IoT devices directly, until a service stands in front |
| The router sends nothing by itself | An alert for unknown devices, and it fetches the lockdown signal |

New numbers: firewall exceptions E18 to E22; exceptions X30 (no record of which device used the home connection) and X31 (the phone as a device with standing access, and targets without a login); X27 of the administration plan covers both containers. Backlog items: the cloud server as relay and exit node; the viewer-only network view; two hardware keys, which is the existing B8.

## Changes to the administration plan

Made in `phase-r-plan.md` with this pull request:

| Where | Change |
|---|---|
| D4, D5 | The laptop signs alone, with the full cost of that stated |
| D12, new | `remote1` runs only while the laptop is away |
| R.5, R.6 | VLAN 31 is laid, defined exactly, with no right for the token |
| R.7, layers, tests | pve1's firewall on the container's network device, and each layer proven alone |
| Lost laptop | Reworded for two containers and for a signing key that stays trusted until home |
| `travel.ps1`, route test | They expect the administration route and, after this plan, the household routes |

## To verify in the lab during the build

| Check | Step |
|---|---|
| Root inside an unprivileged container cannot change its network tag | H.1 |
| Name lookups through the exit node work with the router narrowed to web ports | H.3, H.5 |
| The lockdown mechanism: the router can fetch the signal and accept it only from the owner; what happens when the service is unreachable | H.4 |
| The exit node is advertised and approved for an unprivileged Tailscale in userspace mode, together with host routes | H.5 |
| A grant through one container is enough, and policy tests take the "through" field into account | H.2, H.5 |
| A client that may not use an exit node cannot use it even when it is offered | H.5 |
| An exit node on the laptop beside WSL and the backup VM's fences | H.5 |
| The Android client: a switch for Tailscale's name service; what it does on a foreign network whose range contains an advertised address | H.5 |

## Checked on 2026-10-09

- Tailscale: [exit nodes](https://tailscale.com/docs/features/exit-nodes), [kernel and userspace routers](https://tailscale.com/docs/reference/kernel-vs-userspace-routers), [grants through a router](https://tailscale.com/docs/features/access-control/grants/grants-via), [peer relays](https://tailscale.com/docs/features/peer-relay), [relay servers](https://tailscale.com/docs/reference/derp-servers), and the client source on its main branch for what an exit node carries.
- OpenWrt: the LuCI account tool and the 2026 advisories on its permission layer, listed in the research record.
- Home Assistant: the [installation page](https://www.home-assistant.io/installation/) for the appliance's minimum.
- Several pages were read through a summarising tool. Every command and flag is read again on the pinned version before it goes into a role or a runbook.
