# Research: household access from away (2026-10-09)

Input to `docs/phases/phase-r-household-plan.md`. Three researchers each took one question, read-only, on 2026-10-09, after the owner widened remote access from administration to household use. Each finding says how it was verified: `primary` (vendor documentation, source code, package index), `secondary`, `repository` (this repository), or `not-verified`. Several web pages were read through a tool that summarises, so quoted sentences must be read again at the source before they are copied anywhere. The open points of each section are the checks the plan carries into the lab.

This file is a record. It is not maintained: where it and a later document disagree, the later document wins.

## Tailscale features for a household path

### Recommendation

Build the household path as a second tagged node, separate from the admin one, and give it three jobs in this order of confidence.

1. **Host routes to named household targets** (the household listener, the ESP32, the printer). This is the same mechanism the plan already uses, in userspace mode, and is the low-risk core.
2. **Exit node at home, for "appear from home" only.** Userspace mode supports it by documentation and source. It carries TCP and UDP only and will run at relay speed, so it is not the answer for everyday browsing on public Wi-Fi. By code it gives no access to home networks, which fits the principle of named targets.
3. **Later, with the cloud VM: a peer relay and a second, fast exit node.** The relay speeds up both paths; nothing at home can be a relay behind carrier-grade NAT. This stays an add-on with its own plan.

Policy shape to adopt now:
- Grants name device addresses as sources, never `autogroup:member` or `*`.
- Every grant carries `via` with one tag.
- `autoApprovers` gives each host route to exactly one tag and names only the household tag under `exitNode`.
- The internet grant keeps `"ip": ["*"]`; ports are narrowed on the home router, which is also the layer an account takeover cannot change.
- No grant ever names a phone as destination, because phones cannot refuse inbound connections.

Phones: default to host routes with the exit node off (battery). On an iPhone use VPN On Demand with the home Wi-Fi excepted. On Android there is no supported automatic switch; the owner toggles by hand or accepts the slow detour at home.

Family devices on 192.168.1.0/24: do not advertise host routes into that range. Reach the few that matter by installing Tailscale on them, or defer. 4via6 works but is not worth its awkward addressing here.

Family members later: invite them as users with one grant to the household listener; node sharing cannot deliver a target behind a subnet route.

The router's LuCI and the Grafana dashboard are the owner's item (2) and sit on the management side today (root SSH tunnel, admin listener). This research found no Tailscale feature that changes that; which path may carry a read-only dashboard is a design decision for the plan, not something a policy setting resolves.

### Risks

- Memory gate: the plan's own table leaves 1.54 GiB after one 0.25 GiB container, against a standing gate of 1.5 GiB. A second container with the same ceiling leaves 1.29 GiB on paper. A container's memory is a limit, not a reservation, but exit-node traffic is the heaviest load tailscaled carries and Tailscale publishes no memory figure.
- Speed: both ends behind carrier-grade NAT means relayed traffic through Bengaluru, a region with a single server. Tailscale throttles relays and publishes no rate. Browsing through the home exit node may be too slow to be useful until a peer relay exists.
- Userspace exit node is rated 'acceptable' and 'new' by the vendor, the flag text still says 'beta', and one secondary report describes an exit node failing to advertise from a container. If it fails in the lab, the alternatives are a VM at home or the cloud VM.
- The admin container may reach any internet host on tcp 443 (E16), so the router's firewall would not stop it acting as an HTTPS exit node. Only the device-side flag, the auto-approver list and `via` prevent that. An account takeover can change the last two but not the first.
- Routes are injected into clients regardless of grants. At home, any device with Tailscale left on sends traffic for the advertised home targets through the tunnel; with the exit node also on, local devices become unreachable unless local network access is allowed.
- Host routes inside 192.168.1.0/24 would override the local network on any foreign network using that range, and could cut a phone off from a hotel gateway or resolver that shares an advertised address. They would also need a new router rule into the trusted network.
- A lost phone under D4 is also a node-signing key holder and may be the owner's second factor for GitHub. Cutting it off needs a browser login that may depend on recovery codes.
- `autogroup:member` includes invited users. One grant written with it later would hand every family member the exit node or more.
- The household container terminates every connection in userspace mode. If compromised, it sees all destinations of everyone browsing through it and can alter unencrypted pages. It also holds a non-expiring key like the admin container.
- Traffic leaving the home exit node is attributable to the owner's provider account, whoever in the tailnet sent it.
- An exit node on the Windows laptop is unproven with WSL and the Hyper-V fences; the earlier research advised against it and the source has changed only in part.
- Free-plan terms were searched, not read in full. No bandwidth or exit-node clause was found; the plan is for non-commercial use and its limits can change.

### Open points

- Lab: does `tailscale set --advertise-exit-node` take effect for an unprivileged tailscaled started with --tun=userspace-networking on the pinned 1.102.5, together with advertised host routes, and is it auto-approved for the tag?
- Lab: is a `via` grant alone enough for the client to use the router, or does the client also need a grant to the router itself? The route-injection page says a router is a candidate only when 'Access control rules permit the user to reach the router'. Same check for the exit node.
- Lab: is `via` accepted on the free plan? No page carries a plan note. If not, each route already belongs to one router and the grants work without it, but the exit-node restriction would then rest on there being only one approved exit node.
- Lab: do policy tests take `via` into account, and does a public address in `accept` assert exit-node rights as the docs' deny example implies?
- Lab: does a client not allowed to use an exit node still see it in the app's list?
- Lab: with the internet grant at "*" and the router narrowed to web ports, do name lookups through the exit node work? Does the laptop's 'accept-dns off' preference change which resolver is used while an exit node is on?
- Lab: measure `tailscale netcheck` on the home container and on the phone's mobile network, then `tailscale ping`, for the relay region, delay and real throughput inside India.
- Lab: memory of the household container while a phone browses through it, against the 1.5 GiB gate.
- Lab: what the phone does on a foreign 192.168.1.0/24 network when a /32 inside it is accepted, on the owner's actual phone platform. Not documented for iOS or Android.
- Design option to test, not documented by Tailscale: a router rule from the trusted network to the household container on UDP 41641 might let a phone at home form a direct local path, so leaving Tailscale on at home costs little. Inferred from how direct connections form.
- Owner: iPhone or Android. It decides automatic switching at home as well as node signing (D4).
- Owner: what 'family devices' means concretely (which devices, which services), since that decides between installing Tailscale on them and any route into the trusted network.
- Owner: which ports browsing through home should include (web only, or everything), since the router rule for the household zone encodes that choice.
- Owner: whether the cloud VM is wanted now for speed, or the home exit node is accepted as slow until then.
- Design: which path, if any, may carry a read-only view of the router or the Grafana dashboard. Both sit on the management side today.
- Android broadcast actions for connect, disconnect and exit node exist in the client source but I found no documentation page; whether they are callable by third-party automation apps on the current release is unverified.
- Whether one cloud node may be peer relay and exit node at once: nothing forbids it, nothing confirms it.
- Before any flag or quote goes into a role or runbook: re-read it on the pinned version. Source was read on the main branch.

### Findings

**Method: how were the sources read, and how far can the quotes be trusted?** (`primary`)

Most Tailscale pages were downloaded on 2026-10-09 as raw Markdown (the docs serve `<page>.md`) and read directly, so quotes from them are exact. The same holds for the Tailscale source files on the main branch and the DERP map JSON. Four items came only through a summarising fetch and must be re-read before a quote is copied: the terms of service, the acceptable use policy, the grants examples page and the pricing page layout. Nothing was tested against a tailnet: none exists yet. Source code was read on main, not on the pinned 1.102.5.

Source: Raw pages under https://tailscale.com/docs/ (exit-nodes, kernel-vs-userspace-routers, grants, grants-via, policy-file, route-injection, peer-relay, 4via6-subnets, sharing, invite-any-user, ios-vpn-on-demand, key-expiry, manage-preferences, derp-servers, connection-types, tailscale-system-policies); https://raw.githubusercontent.com/tailscale/tailscale/main/ (ipn/ipnlocal/local.go, ipn/ipnlocal/peerapi.go, wgengine/netstack/netstack.go, cmd/tailscaled/tailscaled.go, wf/firewall.go); https://login.tailscale.com/derpmap/default

**1. Does a node in userspace networking mode (unprivileged user, unprivileged container, no TUN device) work as an exit node?** (`primary`)

Yes, by documentation and by source. The comparison page says: 'Tailscale can also run subnet routers and exit nodes in userspace, without the kernel forwarding packets. This happens when ... tailscaled is run with --tun=userspace-networking (used when running as a regular, non-root user)'. The source agrees: in this mode the IP-forwarding check is skipped (`CheckIPForwarding` returns nil for a userspace router), and the userspace stack handles every packet addressed to a non-local address, which includes internet destinations. So the exit-nodes page warning 'You must enable IP forwarding' applies to kernel mode only. One secondary report (issue 17426) describes an exit node that would not advertise from a Docker container, so the first advertisement is a lab check. The daemon's own help text still labels the mode 'beta'.

Source: https://tailscale.com/docs/reference/kernel-vs-userspace-routers ; local.go (CheckIPForwarding, line 7780 on main) ; netstack.go (shouldProcessInbound, ProcessSubnets) ; tailscaled.go (flag text for --tun) ; https://github.com/tailscale/tailscale/issues/17426 (secondary)

**1. What are the documented limits of a userspace exit node (protocols, performance, DNS)?** (`primary`)

Protocols: TCP and UDP only, and neither is end to end. Tailscale 'terminates TCP and UDP connections from the origin Tailscale peer and makes new outbound connections to the target'. Ping works in a reconstructed form; 'Other ICMP traffic is not relayed', and 'any IP protocol other than TCP or UDP (such as SCTP) is not supported'. So IPsec, GRE and similar cannot pass. Performance is rated 'acceptable' against 'best', maturity 'new (in Tailscale)' against 'stable', and the page recommends kernel mode for 'heavily used' routers while calling userspace 'more than sufficient for smaller numbers of users or low bandwidth'. DNS: 'When Tailscale operates as an exit node, it runs a DNS server for peers behind the exit node', and 'your local DNS is the DNS for the exit node, not your device'. For this lab that means a phone using the home exit node resolves names at the router's dnsmasq, so lab names resolve as they do at home. The home resolver also sees every name the phone looks up.

Source: https://tailscale.com/docs/reference/kernel-vs-userspace-routers ; https://tailscale.com/docs/features/exit-nodes ; https://tailscale.com/docs/features/client/manage-preferences ; https://tailscale.com/docs/reference/dns-in-tailscale

**1. What does a userspace exit node need outbound, and what source address does the internet see?** (`primary`)

Every client flow becomes an ordinary socket opened by the container (`net.Dialer` in the source), so the router's firewall sees the container's own address as the source and can filter by port. The node needs whatever the owner wants browsing to include. A web-only set is name lookups at the router, tcp 80 and 443, and udp 443 (QUIC). Mail, calls, games and app-specific ports each need their own row, or the zone is opened for all tcp and udp towards the internet. This is on top of what Tailscale itself needs (tcp 443, optionally udp 3478 and udp from 41641). The internet sees the home connection's public address, which under carrier-grade NAT is the provider's shared address, not one unique to the house. That narrowing by port on the router is my design inference from the mechanism; the docs do not describe it.

Source: netstack.go (forwardTCP uses net.Dialer; line 1783 on main) ; https://tailscale.com/docs/reference/kernel-vs-userspace-routers ; docs/phases/phase-r-plan.md (E16)

**1. Does an exit node at home give access to the home networks ('as if at home')?** (`primary`)

No, and this matters for the design. The source strips private ranges out of the default route an exit node offers: 192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8, link-local, multicast and Tailscale's own range. The code comment says the default route 'effectively appears to be a "guest wifi": you get internet access, but to additionally get LAN access the LAN(s) need to be offered explicitly as well'. So the exit node carries internet traffic only. Each home target still needs its own advertised host route and its own grant. This keeps the household path a list of named targets, which is what the design principle asks for.

Source: local.go (removeFromDefaultRoute, shrinkDefaultRoute, lines 3461-3490 and 3602-3619 on main)

**1. If userspace mode turned out unsuitable for the exit node, what is the alternative?** (`repository`)

Kernel mode. It needs /dev/net/tun and IP forwarding, and on Proxmox only root@pam can hand a tunnel device to a container (established in the research of 2026-10-08). The practical alternatives are therefore a small VM at home, or the exit node on a cloud VM, where kernel mode is the default and no hypervisor exception is needed. Nothing found today says userspace mode is unsuitable for one or two people browsing; the limit is speed, and the tunnel is likely to be the bottleneck before the container is.

Source: docs/research/2026-10-08-remote-access-research.md (TUN passthrough finding) ; https://tailscale.com/docs/reference/kernel-vs-userspace-routers

**2. How do grants express 'these devices may use the exit node tagged T', and how are exit nodes approved?** (`primary`)

Use of any exit node needs a grant whose destination is `autogroup:internet`: 'Only devices with access to autogroup:internet can use exit nodes'. Adding `"via": ["tag:T"]` restricts which exit node carries it; the via page's own example is `{"src": ["group:tor"], "dst": ["autogroup:internet"], "via": ["tag:exit-node-tor"], "ip": ["*"]}`. Only tags are allowed in `via`. Approval is a double opt-in: the node must advertise itself, and an admin must approve, or `"autoApprovers": {"exitNode": ["tag:T"]}` approves it automatically. Auto-approval applies only when the advertisement first arrives; it is not retroactive. Keep `"ip": ["*"]` on the internet grant: the exit node's DNS service checks whether the client 'would've accepted a packet to 0.0.0.0:53', so a grant narrowed to web ports would probably break name lookups. Narrow ports on the router instead. One page still says 'You cannot restrict the use of specific exit nodes using ACLs' (citing issue 1567, now closed); that sentence is about legacy ACLs, and `via` in grants is the documented answer.

Source: https://tailscale.com/docs/reference/syntax/policy-file (sections 'Subnet routers and exit nodes', 'Auto approvers') ; https://tailscale.com/docs/features/access-control/grants/grants-via ; https://tailscale.com/docs/reference/syntax/grants ; peerapi.go (line 819 on main)

**2. How do I make sure the admin router cannot be used as an exit node, and the household router cannot reach admin targets?** (`primary`)

Admin router as exit node, four locks: (a) it never advertises itself as one, a device-side flag kept in Git, which the admin console cannot set; (b) `autoApprovers.exitNode` names only the household tag; (c) the only `autogroup:internet` grant carries `via` the household tag; (d) policy tests. Note that the router's rule E16 lets the admin container reach any internet host on tcp 443, so the router's firewall would not stop HTTPS browsing through it; the locks are on the Tailscale side and on the device. Household router reaching admin targets: (a) no grant names an admin target with the household tag; (b) `autoApprovers.routes` approves admin host routes for the admin tag only; (c) the exit node's default route excludes all private ranges by code; (d) the household container's zone on the home router has no rule towards the management network. Only (d) survives an account takeover, which is why the two paths need two nodes with two source addresses: one tailscaled has one identity and dials from one address.

Source: https://tailscale.com/docs/reference/syntax/policy-file ; https://tailscale.com/docs/features/exit-nodes ('A device must advertise itself as an exit node') ; local.go ; docs/phases/phase-r-plan.md (E15, E16)

**2. Two tagged routers in one tailnet: how does 'via' pin a destination to one router, and what happens if both advertise the same route?** (`primary`)

With different host routes there is no ambiguity: clients use longest-prefix matching and each /32 belongs to one router. `via` then 'ensures traffic from <source> to <destination> goes through a device with the tag'. If both advertise the exact same prefix they become a failover pair: 'one connector is used at a time by all clients', and 'The oldest connector is the "primary"'. That would silently send admin traffic through whichever node joined first, so the auto-approver list must give each route to one tag only. Two things to know. First, routes are injected regardless of grants: 'Grants control packet filtering, while routes are injected based on what subnet routers advertise and what the control plane approves', so a phone may hold a route to the hypervisor and have its packets dropped. Second, a router is a `via` candidate only if 'Access control rules permit the user to reach the router'. Whether a via grant alone satisfies that, or the client also needs some grant to the router itself, is still not stated; it is the same open check the current plan carries in R.8.

Source: https://tailscale.com/docs/reference/route-injection ; https://tailscale.com/docs/how-to/set-up-high-availability ; https://tailscale.com/docs/features/access-control/grants/grants-via

**2. Example policy with two tags, a laptop that may use both paths and a phone that may use only the household one, with tests.** (`primary`)

Checked against the policy-file, grants, grants-via and route-injection pages only; not validated by the API. Angle brackets are deliberate placeholders. The printer's port is a guess to confirm.

```
{
  // Empty lists: only the Owner or an Admin may assign these tags.
  "tagOwners": {
    "tag:admin-router": [],
    "tag:home-router": [],
  },
  "hosts": {
    "laptop": "<laptop 100.x address>",
    "phone": "<phone 100.x address>",
    "pve1": "10.0.10.10",
    "household-listener": "10.0.50.200",
    "admin-listener": "10.0.50.201",
    "esp32": "10.0.60.10",
    "printer": "10.0.60.182",
  },
  // Each route belongs to exactly one tag. Only the household tag may be an exit node.
  "autoApprovers": {
    "routes": {
      "10.0.10.10/32": ["tag:admin-router"],
      "10.0.50.200/32": ["tag:home-router"],
      "10.0.60.10/32": ["tag:home-router"],
      "10.0.60.182/32": ["tag:home-router"],
    },
    "exitNode": ["tag:home-router"],
  },
  "grants": [
    // Admin path: the laptop only, the hypervisor only.
    {"src": ["laptop"], "dst": ["pve1"], "ip": ["tcp:22", "tcp:8006"], "via": ["tag:admin-router"]},
    // Household path: named devices, named targets.
    {"src": ["laptop", "phone"], "dst": ["household-listener"], "ip": ["tcp:443"], "via": ["tag:home-router"]},
    {"src": ["laptop", "phone"], "dst": ["esp32"], "ip": ["tcp:80"], "via": ["tag:home-router"]},
    {"src": ["laptop", "phone"], "dst": ["printer"], "ip": ["tcp:443"], "via": ["tag:home-router"]},
    // Browsing through the home connection. Keep "*": the exit node's DNS needs port 53.
    {"src": ["laptop", "phone"], "dst": ["autogroup:internet"], "ip": ["*"], "via": ["tag:home-router"]},
  ],
  "tests": [
    {
      "src": "laptop", "proto": "tcp",
      "accept": ["pve1:22", "pve1:8006", "household-listener:443", "esp32:80", "1.1.1.1:443"],
      "deny": ["pve1:3128", "admin-listener:443", "10.0.10.1:22", "tag:admin-router:22", "tag:home-router:22", "phone:80"],
    },
    {
      "src": "phone", "proto": "tcp",
      "accept": ["household-listener:443", "esp32:80", "1.1.1.1:443"],
      "deny": ["pve1:22", "pve1:8006", "admin-listener:443", "10.0.10.1:22", "10.0.10.2:22", "10.0.10.3:22", "tag:admin-router:22", "tag:home-router:22", "laptop:22"],
    },
    {
      "src": "tag:home-router", "proto": "tcp",
      "deny": ["pve1:22", "laptop:22", "phone:80", "tag:admin-router:22", "1.1.1.1:443"],
    },
    {
      "src": "tag:admin-router", "proto": "tcp",
      "deny": ["household-listener:443", "esp32:80", "laptop:22", "phone:80", "tag:home-router:22", "1.1.1.1:443"],
    },
    {
      // any other device of the owner
      "src": "<login>@github", "proto": "tcp",
      "deny": ["pve1:22", "household-listener:443", "1.1.1.1:443"],
    },
  ],
}
```

The public address in the tests follows the docs' own pattern for asserting exit-node rights ('a test that fails if any rule accidentally grants access to a public address'). What the tests cannot show: whether they evaluate `via` at all (not documented), so 'the laptop reaches pve1 through the admin router and not the other' is proven only by a lab test that reads the source address on pve1.

Source: https://tailscale.com/docs/reference/syntax/policy-file (hosts, autoApprovers, tests) ; https://tailscale.com/docs/reference/syntax/grants ; https://tailscale.com/docs/features/access-control/grants/grants-via ; https://tailscale.com/docs/reference/route-injection

**3. Phones: do iOS and Android accept subnet routes by default, and how is an exit node chosen or pinned?** (`primary`)

Routes: yes. 'Windows, macOS, Android, iOS, and tvOS accept routes by default', and clients 'don't probe a router with pings before installing routes'. The app has a 'Use Tailscale subnets' switch to turn this off. Exit node: chosen by hand in the app, per device ('Each device must enable the exit node separately'). Pinning is not available on the free plan: forcing one (`ExitNodeID`) is a system policy delivered by device management, and 'System policies are available for the Standard, Premium, and Enterprise plans'; recommended exit nodes need Standard or higher; mandatory exit nodes need Premium or Enterprise. With one approved exit node and a `via` grant there is only one to choose anyway. Shortcuts on iOS offer 'Use Exit Node' and 'Stop Using Exit Node'; the Android client's source has a matching broadcast action.

Source: https://tailscale.com/docs/reference/route-injection ; https://tailscale.com/docs/features/exit-nodes ; https://tailscale.com/docs/features/tailscale-system-policies ; https://tailscale.com/docs/features/exit-nodes/auto-exit-nodes ; https://tailscale.com/docs/features/exit-nodes/mandatory-exit-nodes ; https://tailscale.com/docs/features/mac-ios-shortcuts

**3. What does 'Allow local network access' do while an exit node is in use?** (`primary`)

'By default, the device connecting to an exit node won't have access to its local network.' The switch is 'Allow LAN access' on Android and 'Allow Local Network Access' on iOS (the system-policy page lists both platforms for it). The source shows why: without it the client adds routes for the local network into the tunnel 'so that we do not leak any traffic'. Consequence at home: a phone that still has the exit node on cannot reach the printer or anything else on the Wi-Fi until the exit node is switched off or the option is on. On a hotel network, leaving it off is the safer setting.

Source: https://tailscale.com/docs/features/exit-nodes ; https://tailscale.com/docs/features/tailscale-system-policies (ExitNodeAllowLANAccess) ; local.go (lines 6655-6665 on main)

**3. Can the phone switch Tailscale off on the home Wi-Fi and on elsewhere?** (`primary`)

iPhone: yes, built in. 'VPN On Demand is currently only available in the iOS and macOS versions'. For Wi-Fi the rule 'Except On' means 'Tailscale will always connect when a Wi-Fi connection is active, however it will disconnect if the current Wi-Fi network is included in the list of excepted networks'; cellular can be set to 'Always'. Limit: only one VPN app may have On Demand active. Android: no built-in equivalent. Two feature requests are open (issues 18730 and 19408, both still open, last updated mid-2026). The Android client's source does accept broadcast actions `com.tailscale.ipn.CONNECT_VPN`, `DISCONNECT_VPN` and `USE_EXIT_NODE` ('IPNReceiver allows external applications to start the VPN'), which an automation app could send on joining or leaving the home network; I found no Tailscale documentation page for them, so treat that as unsupported. Android's own always-on VPN setting does the opposite of what is wanted. If nothing switches it off, a phone at home sends traffic for the advertised home targets through the tunnel: it works, relayed and slower, and Home Assistant logs the household container as the source.

Source: https://tailscale.com/docs/features/client/ios-vpn-on-demand ; https://github.com/tailscale/tailscale/issues/18730 ; https://github.com/tailscale/tailscale/issues/19408 ; https://raw.githubusercontent.com/tailscale/tailscale-android/main/android/src/main/java/com/tailscale/ipn/IPNReceiver.java

**3. Battery impact, key expiry on phones, and can a phone be restricted by policy to household targets?** (`primary`)

Battery: the whole troubleshooting page is two sentences: 'Draining of mobile device batteries is a known issue (#3363). ... Battery drain is most commonly attributed to a device using an exit node for all traffic.' The issue is still open. So the sensible default is subnet routes only, with the exit node switched on when needed. Key expiry: a phone is a user device, so the tailnet's expiry applies (90 days under D7); when it lapses 'connections to/from the given endpoint will stop working' until the owner signs in again in the app. iOS shows a notice, by default 24 hours before; that setting is not listed for Android. Restriction: yes. A grant's source can be a host alias for the phone's own tailnet address, so the phone gets the household grants and nothing else. Do not tag a phone: tags are 'unsuitable for authenticating end-user devices'. One gap: 'iOS does not support blocking incoming connections' and neither does Android, so the policy must never name a phone as a destination; the example tests assert that.

Source: https://tailscale.com/docs/reference/troubleshooting/mobile/battery-drains ; https://tailscale.com/docs/features/access-control/key-expiry ; https://tailscale.com/docs/features/tailscale-system-policies (KeyExpirationNotice) ; https://tailscale.com/docs/features/tags ; https://tailscale.com/docs/features/client/manage-preferences

**4. Speed: what to expect from DERP relays with both ends behind carrier-grade NAT in India, and which regions are nearest?** (`primary`)

The DERP map today has 28 regions. The Indian one is region 6, Bengaluru, with a single server (derp6); most regions have three or more. Next nearest are Singapore (4 servers), Dubai (3) and Hong Kong (3). With one server, an outage of derp6 moves the relay abroad: 'If the DERP region becomes unreachable, the Tailscale client selects the next closest region'. Tailscale publishes no throughput figure for DERP, only that servers 'limit throughput to ensure fairness between everyone using the DERP server' and 'may offer lower maximum throughput'. The one published measurement is a Tailscale blog post of 2026-01-26: Delhi to Minnesota through the Chicago relay, 2.2 Mbit/s sustained and 441 to 478 ms, with the author's line normally giving 30 to 40 Mbit/s. That was an intercontinental path; a path inside India through Bengaluru should have far lower delay, but its throughput is unknown and must be measured with `tailscale netcheck` and `tailscale ping`. The same post states that Jio, Airtel, BSNL and ACT use carrier-grade NAT, commonly the kind that defeats direct connections, so plan for relayed traffic. Browsing or video through a home exit node would run at relay speed.

Source: https://login.tailscale.com/derpmap/default (parsed locally) ; https://tailscale.com/docs/reference/derp-servers ; https://tailscale.com/docs/reference/troubleshooting/poor-performance-tailnet ; https://tailscale.com/docs/reference/connection-types ; https://tailscale.com/blog/peer-relays-international-networks

**4. What are peer relays: requirements, plan, configuration, published gain? Can a node behind carrier-grade NAT be one?** (`primary`)

A peer relay is one of your own tailnet devices that forwards encrypted traffic between two others when they cannot connect directly. Order of preference: direct, then peer relay, then DERP. Requirements: Tailscale 1.86 or later on all parties; any operating system except iOS, Apple TV and Android for the relay; and 'At least one configurable UDP port ... This port must be accessible from other devices in the tailnet'. The blog explains the mechanism: 'both clients establish independent UDP connections inbound to the relay node. The relay doesn't initiate any outbound connections'. So the relay needs a public or port-forwarded UDP port, and nothing behind carrier-grade NAT can be one. Plan: 'Peer Relays are available on all Tailscale plans, including our free Personal plan' (2026-02-18). Configuration: `tailscale set --relay-server-port=<port>` on the relay, and a grant with the capability `tailscale.com/cap/relay`, for example `{"src": ["tag:home-router", "tag:admin-router"], "dst": ["tag:relay"], "app": {"tailscale.com/cap/relay": []}}`. The docs advise that the source should be 'devices in a stable physical location behind a strict NAT', which here means the two home containers, not the phone. Published gain: 27.5 Mbit/s against 2.2 (12.5 times) and about 300 ms against about 450 ms, in the Delhi example, where the relay was a home line with a forwarded port.

Source: https://tailscale.com/docs/features/peer-relay ; https://tailscale.com/blog/peer-relays-ga ; https://tailscale.com/blog/peer-relays-international-networks ; https://tailscale.com/docs/reference/connection-types

**4. Is a small cloud VM suitable as a peer relay and as an exit node, and how does 'exit node at home' compare with 'exit node on the cloud VM'?** (`primary`)

As a relay: yes, this is the documented fit, since it has a reachable UDP port. A cloud VM's public address is usually mapped one-to-one to a private one; discovery normally copes, and `--relay-server-static-endpoints` exists for cases where it does not. As an exit node: yes, and in kernel mode, because a VM has its own tunnel device. Nothing in the docs forbids one node doing both, but I found no statement that confirms the combination. Oracle's free tier: its documentation lists 10 TB of outbound data a month and regions in Mumbai and Hyderabad, and says idle free instances may be reclaimed (read through a search summary, so secondary).

Comparison:
- Privacy on public Wi-Fi: both encrypt everything up to the exit node. At home, the home provider then sees the traffic; in the cloud, the cloud provider does.
- Appearing from home: only the home exit node. Sites see the home provider's shared address. A cloud address is a data-centre address, which some banking and streaming sites treat with suspicion.
- Speed: cloud wins clearly. The phone connects straight to a public address. The home exit node is limited by the relay and by the home line's upload speed.
- Reaching home devices: neither exit node does that; host routes do.
- Dependence: the home exit node dies with pve1; the cloud one does not.
- Cost: the cloud VM is a public server to patch and watch, and a third tag in the policy.

Source: https://tailscale.com/docs/features/peer-relay (static endpoints) ; https://tailscale.com/docs/reference/device-connectivity ; https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm (secondary, via search summary)

**5. Overlapping addresses: what happens on the client when 192.168.1.50/32 is accepted and the local network is also 192.168.1.0/24?** (`primary`)

Tailscale documents the rule for Windows and macOS: 'The operating system will prioritize routes with the longest prefix match'. A /32 beats the local /24, so traffic for .50 goes into the tunnel and whatever device holds .50 on the hotel network becomes unreachable. If an advertised family address happened to equal the foreign network's gateway or DNS server, the phone would lose that network. I found no Tailscale page that states the behaviour for iOS or Android; the same outcome is likely but not verified. The same rule applies at home: with Tailscale on, traffic to a family device on the same Wi-Fi would detour through the tunnel and the household container, which needs a new router rule from the container's zone into the trusted network. Today nothing initiates into that network except E14. Tailscale's own workaround page warns that its fixes can lead to a device sending 'traffic to a public LAN network that was intended for the Tailscale network'.

Source: https://tailscale.com/docs/reference/troubleshooting/network-configuration/lan-traffic-overlapping-subnets ; https://tailscale.com/docs/reference/route-injection ; docs/ARCHITECTURE.md section 6 (matrix)

**5. Is 4via6 the documented answer, does it work with a userspace router and on phones, and is it worth it?** (`primary`)

4via6 is documented for a different problem: two subnet routers in one tailnet advertising the same IPv4 range. It gives each site an IPv6 form of the address, so it also avoids the clash with a hotel network, but Tailscale does not present it as the fix for that; this is my inference. It works with a userspace router: the userspace stack has explicit handling for the 4via6 range. Clients need nothing special ('Other Tailscale clients that use the 4via6 subnet router ... can use older releases'), so phones should work, though no page says so by platform. It is on all plans. Addressing: the router advertises the output of `tailscale debug via <site-id> 192.168.1.50/32`, and the device is reached either as the name `192-168-1-50-via-<site-id>`, which needs Tailscale's name service that the current plan switches off, or as a long IPv6 literal in brackets. Policy must name the IPv6 form. My judgement: not worth it for a handful of family devices. Simpler ways, in order: install Tailscale on the family device itself, which the tags page implies is the normal case (subnet routers are for adding devices 'without installing the Tailscale client'), so it is reached at its own tailnet address with no route, no overlap and its own grant; or give the few devices that must be reached fixed addresses in a range that does not clash; or use the reserved renumbering of the trusted network to 10.0.20.0/24.

Source: https://tailscale.com/docs/features/subnet-routers/4via6-subnets ; https://tailscale.com/docs/reference/syntax/policy-file ('4via6 requires IPv6 not IPv4') ; netstack.go (viaRange, lines 1251 and 1323 on main) ; https://tailscale.com/docs/features/tags ; docs/ARCHITECTURE.md section 6 (10.0.20.0/24 reserved)

**6. Sharing with family later: user limit, invite versus sharing a node, and how policy would give a family member only Home Assistant.** (`primary`)

The free plan allows 'Up to 6 users' and lists 3 access-control groups; the pricing page says group limits are not currently enforced. Two mechanisms exist. Inviting a person into the tailnet gives them their own login and counts as a user; 'inviting external users into your tailnet will give them access to subnet routers', subject to grants. Sharing a single node is for people with their own tailnet, and 'Shared machines do not advertise subnets to the tailnets they're shared into'. Home Assistant sits behind a subnet route, so sharing the household router would not give access to it; sharing can pass on exit-node use only. So a family member is invited as a user and gets one grant: source their login, destination the household listener on tcp 443, via the household tag. What this fixes in the policy shape now:
- Never use `autogroup:member` or `*` as a source. `autogroup:member` covers 'any user who is a direct member (including all invited users)'.
- Keep the owner's grants on device addresses, as the plan already does.
- Each family device must be signed under node signing, by the owner.
- 'A Tailscale user account may not be shared or used by multiple individuals', so family phones must not use the owner's login.
- User approval stays on.

Source: https://tailscale.com/pricing ; https://tailscale.com/docs/features/sharing ; https://tailscale.com/docs/features/sharing/how-to/invite-any-user ; https://tailscale.com/docs/reference/syntax/policy-file (autogroups)

**7. A lost or unlocked phone: what does it reach, and how fast can it be cut off?** (`primary`)

It reaches exactly the household grants: the household listener, where Home Assistant has its own login, the ESP32 page and the printer, and browsing through home. It does not reach the admin side, by policy and, independently, by the home router's rules for the household zone. That is roughly what the home Wi-Fi password gives today under E4 and E9, minus the trusted network itself. Cut-off: removing the device in the admin console means 'The device will immediately lose connection to all resources in the tailnet'. Two cautions. The removal needs a browser with the GitHub login; if the phone was also the second factor, the recovery codes are needed. And under D4 the phone is a signer for node signing, so its signing key must also be withdrawn from the laptop. A removed device 'can be added back to the tailnet without needing re-authorization by a tailnet admin' when device approval is off, which it will be; what node signing does to a re-added device is the open drill item the plan already carries.

Source: https://tailscale.com/docs/features/access-control/device-management/how-to/remove ; docs/phases/phase-r-plan.md (D4, 'Lost laptop') ; docs/ARCHITECTURE.md section 6 (E4, E9)

**7. Can a wrongly written policy turn the exit node into an open relay, and who can see household traffic?** (`primary`)

Open relay: not to the internet. Only tailnet devices with a grant to `autogroup:internet` can use it. The failure mode is a wide source: the default allow-all policy, `*`, or `autogroup:member`, which would include every invited family member, or sharing the node with 'Allow use as an exit node' ticked. Whatever is browsed through it leaves from the home connection and is attributable to the owner's provider account. Limiting the zone's outbound ports on the router, and never opening tcp 25, bounds that. Visibility: Tailscale and its relays cannot read content ('it's impossible for a DERP server to decrypt your traffic'), and the same end-to-end encryption holds through a peer relay. Tailscale does not log exit-node destinations ('By default, destination logging is disabled ... for privacy, abuse, and security purposes', and enabling it needs a paid plan and a sales contract). The exit node itself sees every destination and any unencrypted content, and in userspace mode it terminates each connection, so a compromised household container could read or alter plain HTTP. The home router and the provider see the flows; the home resolver sees the names. Pages such as the ESP32's plain HTTP travel encrypted to the container and unencrypted inside the house, as they do today.

Source: https://tailscale.com/docs/features/exit-nodes ; https://tailscale.com/docs/reference/derp-servers ; https://tailscale.com/docs/reference/connection-types ; https://tailscale.com/docs/features/sharing

**7. Do Tailscale's terms for the free plan say anything about exit nodes or bandwidth?** (`secondary`)

I found no clause on exit nodes, bandwidth or relay usage in the terms of service (last updated 2026-08-25) or the acceptable use policy (last updated 2025-06-30). Both were searched by keyword in the downloaded page and read through a summarising fetch, not line by line, so this is 'not found', not 'does not exist'. What is stated: the service is granted 'solely for your own personal use or internal business purposes (as applicable depending on your Plan)'; reselling, renting or leasing it is prohibited; the Personal plan 'is only suitable for non-commercial use'. Exit nodes and peer relays are on all plans. Tagged devices count against '50 tagged resources included', and the pricing page gives exit nodes as an example of such resources; two home containers and a cloud VM use three. The practical bandwidth limit is technical: relays throttle 'to ensure fairness'.

Source: https://tailscale.com/terms ; https://tailscale.com/tailscale-aup ; https://tailscale.com/pricing ; https://tailscale.com/docs/features/exit-nodes

**Does the earlier advice 'do not use an exit node on the Windows laptop' still hold, now that the owner wants browsing through home on the laptop too?** (`primary`)

Partly. The research of 2026-10-08 based it on an unimplemented 'permitHyperV' step in the Windows firewall code; that TODO is still there. But the routing code now treats Hyper-V interfaces (those whose hardware address starts 00:15:5d) as internal and keeps them reachable while an exit node is on, with the comment 'enabling exit nodes with the default tailnet configuration breaks WSL2 DNS without this'. On this laptop that classification would cover WSL and also the host adapters of the two Hyper-V switches used for the backup VM. So an exit node on the laptop is no longer ruled out by the source, but it is unproven here and interacts with the workstation fences. It needs its own lab test before the plan promises it; the phone has no such complication.

Source: local.go (internalAndExternalInterfacesFrom, lines 3636-3666 on main) ; wf/firewall.go (line 177 on main) ; docs/research/2026-10-08-remote-access-research.md (client section)

## The home side: where the path lands, rules, dashboards, Home Assistant timing

### Recommendation

Land the household path on a second small container that is separate from the admin container in a way the router can see without trusting an address: option (a) with a VLAN and zone of its own (variant a'), or, if a second VLAN is judged too much, option (a) inside VLAN 30 with the hypervisor's ipfilter enabled on both containers and proven by a spoofing test. Do not build option (c). Option (b), the container inside the trusted network, is the cheapest (no router rule at all) and the only one where family devices see a local source, but it gives a tailnet-reachable machine layer-2 adjacency to every family device, lets a compromise of it borrow the workstation's addresses for E1 to E3 exactly while the laptop travels, puts the family network on the trunk to the hypervisor and widens the provisioning token to VLAN 20. If the owner's real need under 'family devices' turns out to be broad access to PCs in 192.168.1.0/24, (b) with ipfilter is the honest fallback and the price above should be recorded as an exception; if it is one or two named devices, (a') with named rows is better.

Rules for the household address in (a'): ESP32 tcp 80, the printer's ports, 10.0.50.200 tcp 443 (written now, live from Phase 10), the internet for browsing, the workstation's SSH to it, and family devices only as named rows with reservations. Decide whether the house's forced DNS applies to remote browsing. Never advertise 192.168.1.0/24 as a whole; use host routes.

Names: use the public wildcard records the design already decided (Q5); do not make the router a tailnet resolver.

Dashboard: keep root LuCI where it is (loopback, SSH tunnel, home). Do not expose a read-only LuCI login to the household path: the mechanism exists on 25.12, but the account tool calls itself experimental, the ACL layer had several bypasses in 2026, one of them without a listed fix, and any network listener also exposes the root password prompt without brute-force protection. Before the monitoring phase the only no-login, read-only source is the exporter packages (a few KB each, already designed as B3); bringing them forward is cheap, but they are numbers, not a dashboard. The owner should decide between (1) waiting for Grafana and deciding now that a viewer-only home-network dashboard gets a route on the household listener, (2) a pushed status page on the household container (custom code), or (3) nothing until Phase 9.

Memory: a second container at the plan's ceiling takes the host to 1.29 GiB, 0.21 under the gate; keep the household container at 256 MiB or more, lower the admin container after its measurement, and let the worker give the difference (about 0.1 to 0.25 GiB).

Home Assistant: put the trade to the owner as laid out (appliance VM 2.2 GiB fixed and a squeeze in Phases 11 to 13; container form about 1 GiB ceiling with a root-only feature question; cluster path nothing before Phase 14). It is the larger decision behind this request, because both stated interests, device control and dashboards, end in it.

### Risks

- A shared segment defeats address-based separation: in VLAN 30 a compromised household container can take 10.0.30.10 and inherit E15; in VLAN 20 it can take 192.168.1.196 or .197 (free while the laptop travels) and inherit E1 to E3 on the router, pve1 and the access points. Only a zone per path or the hypervisor's ipfilter closes it.
- Option (b) gives a remote attacker who owns the container layer-2 presence in the family network: ARP spoofing and interception of family devices, with the router's firewall out of the picture.
- Option (b) widens the OpenTofu token (held on the travelling laptop) to attach guests to the family network, and puts family-network frames on the hypervisor's bridge.
- Browsing through home needs a wide rule (every port to the internet) for a container that is reachable from the tailnet; the plan's narrow E16 logic does not apply to it. As an exit node the container also carries far more traffic and memory load than the admin container, in a mode the vendor rates slower and newer.
- 192.168.1.0/24 is a very common foreign range. Advertising it whole breaks the client's local network away from home and can send sessions to a stranger's device; at home a phone with Tailscale left on would detour home traffic through the tunnel.
- The 2026-10-08 research found that an exit node on the Windows laptop may cut WSL off (block-all filter, Hyper-V permit unimplemented). Browsing through home on the laptop collides with the admin tooling until tested.
- Exposing LuCI on any network address ends X6's mitigation: the root password prompt becomes reachable there, LuCI has no brute-force protection, and the rpcd ACL layer had several bypasses in 2026 (CVE-2026-62947 lists no patched version and covers cgi-io up to 25.12.4; the router ran 25.12.2 at the last inventory).
- A read-only LuCI login with 'list read *' can read the Wi-Fi keys and the whole network and firewall configuration; 'read-only' is not 'harmless'.
- Grafana is on the admin listener by design; without a design decision the household path, and so the phone, will never see the planned dashboards.
- An early Home Assistant VM at the vendor minimum (2 GB plus overhead) does not fit beside the full platform on 16 GB: the squeeze arrives in Phases 11 to 13 unless levers are pulled or the phase order changes.
- An appliance in VLAN 50 becomes a neighbour of the cluster's host services, which the Talos firewall design opens to the whole subnet; in VLAN 60 it sits among the least trusted devices while holding every device credential.
- Home Assistant before Phase 9 and 10 has no monitoring, no TLS, no off-site backup (B25 is open) and updates itself outside Git; each is an exception against the definition of done.
- Every web page was read through a summarising fetch tool. Package sizes are download sizes of the 25.12.2 release directory, not installed sizes, and dependency sizes were not read; quotes must be re-read at the source before they are copied into repository documents.
- The phone becomes a device with standing access to the home. It is also a node-signing device under D4; its loss now matters for more than signing.

### Open points

- Owner: what does 'reach family devices' mean concretely: which devices, which services? This decides between named rows (a') and membership in the trusted network (b).
- Owner: which VLAN number and subnet for a household zone, if one is created (VLAN 40 is reserved for a DMZ; the convention is 10.0.<VLAN>.0/24).
- Owner: should the house's forced DNS and DoT block apply to browsing through home?
- Owner: dashboard before Phase 9: wait, a pushed status page, or exporters only; and whether a viewer-only home-network dashboard may be routed on the household listener later (a change to section 7).
- Owner: Home Assistant early as an appliance, or in the cluster at Phase 14; if early, which form and which VLAN.
- Lab: does the hypervisor's ipfilter on a container NIC stop both a foreign source address and ARP spoofing, and can the OpenTofu token enable the guest firewall and the per-NIC flag? Check on PVE 9.2 with a throwaway container.
- Lab: after adding a tagged VLAN to bridge-vids, confirm the host itself holds no membership and no address in it ('bridge vlan show', 'ip -br addr').
- Lab: can root inside an unprivileged container really change its address and send from it (expected yes)? This is the premise of the spoofing finding.
- Lab: the ESP32's and the printer's real listening ports, probed from a trusted device.
- Lab: simulated install of the exporter packages on the router and on one access point to read the true installed size including lua, luasocket, uhttpd-mod-lua and libubus-lua; whether lua is already present on a 25.12 ucode LuCI system was not checked.
- Lab or documentation: does LuCI's login form on 25.12 accept a non-root rpcd login, and what the smallest read list for a status-only viewer is. Only if the owner wants option 3(ii) despite the recommendation.
- Documentation: whether CVE-2026-62947 is fixed in a 25.12 point release after 25.12.4, and the router's current release (25.12.2 at the inventory of 2026-10-05).
- Tailscale side, outside this question but needed by the answer: does an exit node work in userspace mode on Linux without kernel forwarding (the exit-node page states IP forwarding as a prerequisite for Linux and calls the Android and macOS exit nodes userspace implementations; the userspace page read today is silent); if not, the household container needs kernel mode, which means a tunnel device that only root@pam can hand to a container, or a small VM (about 0.4 GiB more).
- Tailscale side: how one client is steered to two subnet routers with different host routes, how overlapping home ranges are handled on phones, and whether the phone can be limited to the household container by policy.
- Windows: does the default firewall on the family PCs admit a source outside their subnet for the services the owner wants (from memory it does not for file sharing)?
- Home Assistant: real memory use of the container form, whether Proxmox 9.2 can create a container from an OCI image with the token alone, the default port and the storage minimum of the appliance; none verified today.
- Talos firewall: if any non-cluster guest is placed in VLAN 50, the rules that admit 10.0.50.0/24 need narrowing to node addresses; a design change to section 5.
- The plan's home-and-away logic covers the laptop only. A phone that stays connected at home needs its own answer (accept-routes behaviour on iOS or Android was not researched here).

### Findings

**1. Repository baseline: what the router, hypervisor and plan look like today (the facts every option builds on)** (`repository`)

Router template facts. Zones are a literal loop ['lan','mgmt','servers','iot','guest'] with input/forward REJECT (firewall.j2 line 22); four more literal zone loops exist for Router-DHCP, Router-DNS, Router-NTP, Router-Ping (lines 65-102) and a sixth for Force-DNS and Block-DoT (line 291, client zones only). Zone-wide grants are 'config forwarding': trusted_to_wan, guest_to_wan, e8_iot_to_wan, e9_trusted_to_iot (lines 41-55). E4 is zone-wide for trusted: src lan -> servers 10.0.50.200 tcp 80 443 (lines 203-210). E1 to E3 are scoped by src_ip 192.168.1.196/.197 inside zone lan. network.j2: vlan20 is on lan2, lan3, lan4 only; lan1 (the trunk to pve1) carries vlan10 untagged and vlan50 tagged; no VLAN 30 exists yet. dhcp.j2: the trusted pool is .100 to .249 (start 100, limit 150); the only reservations are the workstation's two adapters, the ESP32 (10.0.60.10) and the printer (10.0.60.182). No family device has a reservation. IMPORTANT correction to the task text: dhcp.j2 contains no 'list address' line and no rebind_domain today, so the router does NOT yet answer app.<zone> with 10.0.50.200; that split-horizon entry is designed (ARCHITECTURE section 6) and arrives with Phase 10. Hypervisor: pve_guest_vlans is [50]; interfaces.j2 renders it as bridge-vids; the token's network grant is the single path /sdn/zones/localnetwork/vmbr0/{{ pve_guest_vlans | first }} (the trap the plan already fixes in R.6); the only pool is 'talos'; host.fw accepts by source address and then drops the host's own two subnets on the management ports (X10 loop over pve_mgmt_network and pve_p2p_network only). The plan's cost table: 15.54 - 1.85 - 11.90 - 0.25 = 1.54 GiB against a 1.5 GiB gate; 11.90 is 3.0 (control plane) + 8.5 (worker) + 0.4 (QEMU overhead).

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\firewall.j2; network.j2; dhcp.j2; infrastructure\ansible\playbooks\group_vars\proxmox.yaml:24-28,79-97; infrastructure\ansible\roles\pve_host\tasks\firewall.yaml:26-41; docs\phases\phase-r-plan.md:273-285; docs\ARCHITECTURE.md:157-186,343-389

**1. A finding that applies to options (a) and (b) alike: a different source ADDRESS is not enough when two hosts share one layer-2 segment** (`primary`)

The design principle says the router must be able to tell the two paths apart. The router can only trust what the container cannot forge. The VLAN tag is set by the hypervisor on the container's virtual port and the container cannot change it, so the ingress ZONE is unforgeable. The source ADDRESS inside a segment is forgeable by root inside the container (an unprivileged container's root still holds network-admin rights in its own network namespace; this is reasoning, not tested). Consequences: (a) if remote2 shares VLAN 30 with remote1, a compromised remote2 can take 10.0.30.10 (trivially while remote1 is stopped, otherwise by ARP games) and inherit E15, pve1 tcp 22 and 8006. (b) if the household container sits in VLAN 20, a compromised container can take 192.168.1.196 or .197, most easily exactly when the laptop is travelling and those addresses are free, and inherit E1 to E3 at the router AND the matching accept rows on pve1 and the access points. ARCHITECTURE already records this spoofing as X9, accepted because the attacker had to be inside the house; with a tailnet-facing container in that segment the premise changes to 'whoever compromises the container'. Every target behind E1 to E3 still needs a key, certificate or second factor. Two ways to close it: (1) give the household path its own VLAN and zone, so the router separates by ingress interface; (2) keep a shared segment and enable the Proxmox guest firewall on the container's network device with the 'ipfilter' option, which drops outgoing traffic whose source is not the configured address (Proxmox documents this for containers: 'the configured IP addresses will be implicitly added'; 'macfilter' defaults to on). Option 2 is a hypervisor-side control that Tailscale and the account cannot change, but it is a second enforcement point to maintain, it needs firewall=1 on the NIC plus the guest-level enable, and whether the OpenTofu token may set it and whether it also stops ARP spoofing was not verified.

Source: https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html (ipfilter, macfilter, per-NIC firewall flag; read 2026-10-09 through a summarising fetch); docs\ARCHITECTURE.md:376 and X9 at line 715

**1(a). A second container 'remote2' in zone remote (VLAN 30) with its own address and explicit exceptions** (`repository`)

Changes in the repository. Router firewall.j2: one more Jinja set for the household address; no new zone, no change to the zone loops (the plan already adds 'remote' to the zone and Router-DNS loops). New rules, each with src 'remote' and src_ip = the household address: ESP32 (dest iot, 10.0.60.10, tcp 80); printer (dest iot, 10.0.60.182, the ports the owner wants); household listener (dest servers, 10.0.50.200, tcp 443, can be written now as E3 was, usable from Phase 10); internet for browsing through home (dest wan, all protocols; this also covers what Tailscale itself needs, so no separate E16-style row); workstation -> household container tcp 22 for configuration (like E17); family devices (dest lan, one rule per named device and port). That is 5 rules without family devices, plus one per family device; each family device also needs a 'config host' reservation in dhcp.j2 and its MAC in the private inventory, because none has a fixed address today. network.j2 and dhcp.j2: nothing beyond the plan's VLAN 30 work. Hypervisor: no new VLAN on the trunk; one more token-created container; host.fw unchanged (nothing from the household address is admitted, and the plan's drop for the rest of 10.0.30.0/24 already covers it). If the forced-DNS policy of the house should also apply to remote browsing, 'remote' (or the household address) must be added to the Force-DNS and Block-DoT loop; otherwise exit-node clients can use any resolver. Exposure if the container is compromised: exactly those rows (one web port on the ESP32, the printer ports, the household listener, the named family devices, the whole internet), plus layer-2 adjacency to remote1 (whose own filter drops inbound) and the address-spoofing path to E15 described above. Can the router tell the paths apart: yes by source address, and robustly only with the hypervisor's ipfilter or with a VLAN of its own. Variant (a'): the household container in its OWN VLAN and zone (number to be chosen by the owner, 10.0.<VLAN>.0/24 by the repository's convention; VLAN 40 is reserved for a DMZ and should not be reused silently). Cost of the variant: one more bridge-vlan on lan1, one more interface, one more name in the zone loop and the Router-DNS loop, one more dhcp 'ignore' section, one more entry in pve_guest_vlans and one more SDN ACL row; benefit: separation by ingress interface, no spoofing path, and the rule 'no path between the admin and household containers' is a zone default instead of two host filters.

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\firewall.j2:22-102,203-210,288-308; network.j2:26-58; dhcp.j2:20-93; docs\phases\phase-r-plan.md:73-96

**1(b). A second container inside the trusted network (VLAN 20) with a fixed address** (`repository`)

Changes in the repository. Router network.j2: add 'lan1:t' to bridge-vlan 'vlan20' (today the loop covers lan2 to lan4 only) and update the port comment; that is a 'network' change, so the same few seconds of household interruption as R.5. Router firewall.j2: NO new rule at all. The container is a member of zone lan and inherits trusted_to_wan (internet, all ports), E4 (10.0.50.200 tcp 80 443), e9_trusted_to_iot (the whole IoT network, all ports), Router-DHCP/DNS/NTP/Ping, Force-DNS and Block-DoT. The workstation reaches the container's SSH inside the segment, so not even an E17-style rule is needed. dhcp.j2: optionally a reservation that documents the address; the address must lie outside the pool .100 to .249. Hypervisor group_vars: pve_guest_vlans gains 20 (and the explicit-path fix of R.6 becomes mandatory), pve_acls gains /sdn/zones/localnetwork/vmbr0/20 for terraform@pve. Recommended in pve_host/tasks/firewall.yaml: add 192.168.1.0/24 to the X10 drop loop; the accept rows for .196/.197 come first, so nothing breaks, and it keeps the built-in management set from opening the host to the whole trusted network if the host ever received an address there. What it changes for the hypervisor's exposure: frames of the family network now reach the host's bridge. The host must hold no address in VLAN 20 (no vmbr0.20, not even for a test); with a VLAN-aware bridge the host's own stack is only on the untagged VLAN, so trusted devices have nothing to talk to on the host (expected behaviour, not verified today; check with 'bridge vlan show' and 'ip -br addr' after the change). The larger change is to the provisioning token: terraform@pve, whose secret lives on the travelling laptop, gains the right to attach any guest to the family network. What it changes for 'VLAN membership confers no rights': that rule is written for VLAN 10. VLAN 20 is the one network where membership DOES confer rights by design (internet, E4, E9). Option (b) therefore deliberately uses rights by membership for a machine that is reachable from the tailnet, which is the opposite of the plan's style 'every rule names one device and one port'. Exposure if the container is compromised: everything a hostile phone on the home Wi-Fi has. All of 192.168.1.0/24 at layer 2, where the router's firewall sees nothing (ARP spoofing and interception of family devices and of the workstation when it is home); the whole IoT network on every port; the household listener; the internet on every port; and, by taking a workstation address, E1 to E3 (router SSH, pve1, access points, cluster API, admin listener), each still behind a key or second factor. Can the router tell the paths apart: admin arrives in zone remote, household in zone lan, so yes and by zone; but the household path is by construction indistinguishable from any family device, and distinguishable from the workstation only by a forgeable address unless the hypervisor's ipfilter is enabled on that NIC. Practical advantage that should be stated: family devices see a source in their own subnet. Windows' default firewall scopes file sharing and similar services to the local subnet (from memory, not verified), so option (a) may be blocked by the family devices themselves even when the router allows it, while (b) just works.

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\network.j2:34-39; firewall.j2:41-55,203-210; infrastructure\ansible\roles\pve_host\templates\interfaces.j2:12-19; infrastructure\ansible\playbooks\group_vars\proxmox.yaml:26,74-97; docs\ARCHITECTURE.md:327,376

**1(c). One container with two addresses, or two Tailscale instances in one container** (`not-verified`)

One tailscaled with two addresses does not work for the purpose: in userspace mode tailscaled opens ordinary sockets and the kernel picks the source address by DESTINATION, not by which tailnet client asked. The router would see 'traffic to pve1 from address A, traffic to the ESP32 from address B' whoever originated it, so the separation between laptop-admin and phone-household would rest on the Tailscale policy alone, the one layer an account takeover can rewrite. Two tailscaled instances (two state directories, two sockets, two tailnet identities, two interfaces, routing and nftables rules keyed on the user each runs as) can be made to leave from different addresses (my reasoning from how userspace mode dials; not tested), but the separation then lives inside the container. A compromise of that one machine holds both addresses and both node keys, so the router can no longer tell the paths apart in exactly the case the router layer exists for, and a flaw reached through the household use (which carries arbitrary browsing traffic) lands on the machine that can reach the hypervisor. It saves one container's ceiling (0.25 GiB on paper) and one rebuild procedure. It fails the stated design principle.

Source: Reasoning from docs\research\2026-10-08-remote-access-research.md:86-90 (userspace mode dials from the host with an ordinary socket) and the plan's three-layer table, phase-r-plan.md:24-30

**1. Memory: what a second container does to the 1.5 GiB gate** (`repository`)

Plan as written: 15.54 - 1.85 - 11.90 - 0.25 = 1.54 GiB left; margin 0.04. Second container at the same 256 MiB ceiling: 15.54 - 1.85 - 11.90 - 0.50 = 1.29 GiB, 0.21 under the gate. By the standing rule (ARCHITECTURE section 4: headroom is never traded away, the worker shrinks by the difference) the worker goes from 8.5 to about 8.25 GiB. In cluster terms: worker 8704 MiB gives 8704 - 560 - 5367 = 2777 raw and 1907 practical for applications; at 8448 MiB it is 2521 raw and 1676 practical, so the second container costs about 230 MiB of application room on paper. A container limit is a ceiling, not a reservation, so real use is lower; the plan's memory drill decides. Two honest caveats. First, the household container is the one that should NOT be squeezed: as an exit node it carries browsing and video for laptop and phone through the userspace network stack, and the research already cites an out-of-memory report at 128 MB under heavy traffic; the admin container is the candidate for 128 MiB after measurement (0.125 + 0.25 = 0.375, left 1.415, worker gives about 0.1 GiB). Second, tailscaled's memory under exit-node load is not published; treat every figure as to be measured. Option (c) keeps the plan's 1.54 on paper but puts two tailscaled processes under one 256 MiB ceiling.

Source: docs\phases\phase-r-plan.md:273-285; docs\ARCHITECTURE.md:184-204,268-299; research file line 116-120 (memory, not-verified there)

**2. Targets and rules, one by one** (`repository`)

ESP32, 10.0.60.10 (reserved in dhcp.j2; runs ESPHome; its web interface answers; driven by HTTP shortcuts by address). Port for the phone: tcp 80, the ESPHome web server default (from memory; confirm with one probe). As a trusted device: covered by E9 (forwarding lan -> iot, everything). Otherwise: new rule household address -> iot 10.0.60.10 tcp 80. ESPHome's native API is tcp 6053 (ESPHome docs: 'Defaults to 6053'; Home Assistant connects to the device) and is not needed by a phone. Note the traffic is plain HTTP between the home container and the ESP32, as it is today on Wi-Fi.
Printer, 10.0.60.182 (reserved; 'its printing ports answer from the trusted network', backlog B17). Typical ports: IPP tcp 631, raw tcp 9100, status page tcp 80/443 (from memory; read the real ones off the device). As trusted: E9. Otherwise: new rule to 10.0.60.182 on the chosen ports. Phone discovery (AirPrint, Mopria) does not cross a tunnel any more than it crosses VLANs; printing from away works by address only.
Family devices, 192.168.1.0/24. Nothing is defined today: no reservations, no list of devices or services; the only named one is 'a family PC' on AP2's second port. As a trusted device: no router rule exists or is possible, the traffic never touches the router. Otherwise: one rule per device and port (dest lan, dest_ip), each needing a DHCP reservation first. Two hazards regardless of option: 192.168.1.0/24 is one of the most common hotel and home ranges, so advertising the whole /24 into the tailnet breaks the client's local network on a foreign 192.168.1.x and can deliver sessions to a stranger's machine (already listed as a risk in the 2026-10-08 research); and a phone at home with Tailscale left on would send home traffic through the tunnel. Only /32 host routes of named devices avoid the first; the architecture's reserved renumbering of the trusted network to 10.0.20.0/24 removes it for good.
Household listener, 10.0.50.200 tcp 443 (and 80 for the redirect). Does not exist until Phase 10; the rule E4 is already in the template. As trusted: E4. Otherwise: new rule to 10.0.50.200 tcp 443. Home Assistant behind it is Phase 14 (B5).
Internet through home. As trusted: the forwarding trusted_to_wan, with the house's forced DNS and the DoT block applied. Otherwise: a new, wide rule household address -> wan (all ports), plus a decision whether Force-DNS and Block-DoT should apply.
Lab names from away. As built, the router answers no lab name yet (no address= line in dhcp.j2). As designed (Q5, answered): two public DNS-only wildcard records *.<zone> -> 10.0.50.200 and *.admin.<zone> -> 10.0.50.201 are published in Cloudflare, precisely so clients that bypass the router's resolver still resolve lab names. A remote client therefore needs NO home resolver for lab names: any public resolver returns 10.0.50.200 and the tunnel carries the connection. Can a remote client use the router as resolver through the tunnel: technically yes. The container's own lookups already go to the router (Router-DNS for the zone); a tailnet split-DNS entry for <zone> pointing at the router's address in the container's network, plus a host route to that address, would work, and userspace mode carries UDP. dnsmasq has localservice on, which admits the container's subnet. Should it: no for lab names. It would put the tailnet's name service back in play (the plan turns it off and sets accept-dns off on the laptop because of dnscrypt-proxy and WSL), it adds a route to a router address, and it buys nothing the wildcard does not. The one case for it is device names in 'lan' or home.arpa (the ESP32's name); the owner's shortcuts use addresses, so it is not needed today. When an exit node is in use, Tailscale documents that the exit node 'runs a DNS server for peers behind the exit node to use', so with browsing-through-home switched on, lookups end at the home router anyway.

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\dhcp.j2:4-18,81-93; firewall.j2:41-55,203-210,288-308; docs\backlog.md B4, B5, B17; docs\ARCHITECTURE.md:380-384,916; https://esphome.io/components/api/ ; https://tailscale.com/kb/1103/exit-nodes

**3. LuCI today: where it listens and how it is reached** (`repository`)

uhttpd listens on 127.0.0.1:80 and 127.0.0.1:443 only (uhttpd.j2 lines 4-5; the access-point template does the same). No firewall rule mentions it. It is reached with 'just luci', which is 'ssh -N -L 8443:127.0.0.1:443 root@192.168.1.53' (justfile line 132-133), so through E1: root SSH, key-only, from the workstation's two addresses. Inside the tunnel LuCI asks for the root password, which still works there (components/openwrt.md line 82). This is exception X6's mitigation and decision 10. Installed on the router: luci 26.082, rpcd 2025.12.03 with the file, iwinfo, luci, rpcsys, rrdns and ucode modules, uhttpd-mod-ubus; OpenWrt 25.12.2 at the inventory of 2026-10-05; 25.6 MB free on the overlay, 6.7 MB on each access point.

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\uhttpd.j2:3-5; justfile:131-133; docs\components\openwrt.md:77-83; private\inventory\router-m30.txt:4,43,171-231; private\inventory\ap1.txt:43

**3(i). LuCI as root through the admin path** (`repository`)

Needs the router's root SSH reachable from the admin container (a rule remote1 -> router input tcp 22, pinned with dest_ip to the zone's router address) and the route advertised. The plan's D1 lists exactly this as the refused alternative: under D6 no router change is allowed remotely, so it buys reading only, and it puts root on the device that enforces the segmentation within reach of the remote endpoint. It works on the laptop only (SSH key, tunnel); the phone gets nothing. Exposes: full root on the router to whoever holds the operator key and the tunnel.

Source: docs\phases\phase-r-plan.md:38 (D1), 43 (D6)

**3(ii). A read-only LuCI login: supported? what can it see? is the ACL a security boundary? how would uhttpd listen on one extra address?** (`primary`)

Supported in mechanism: /etc/config/rpcd takes 'config login' sections with username, password ('$p$<user>' for a system account's shadow entry, or a crypt hash) and 'list read' / 'list write' naming ACL groups; groups are JSON files in /usr/share/rpcd/acl.d with read and write sections for ubus, uci and file. A login with read lists and no write list is a read-only login. The 25.12 LuCI feed ships luci-app-acl ('LuCI account management module', 4.0 KB) that edits exactly this, with per-group choices denied, readonly, full, individual. Its own page says: 'The LuCI ACL management is in an experimental stage! It does not yet work reliably with all applications'. What a read login still sees depends on the groups listed, and 'list read *' is far too wide: the read side of the network groups includes the uci files 'network' and 'wireless' (luci-base-network-status alone grants read on both), so the viewer can read every Wi-Fi key; other read groups run 'nft list ruleset', the routing and neighbour tables, the system log, the DHCP leases and the connection list. A status-only viewer would need a hand-picked list (for example luci-base and luci-mod-status-realtime) and even then gets device names, addresses and MAC addresses of the household.
Is the ACL a security boundary: OpenWrt publishes no threat-model statement either way (the ubus and security pages are silent). In practice the project treats bypasses as vulnerabilities, and 2026 produced several: CVE-2026-62947 (published 2026-06-29, cgi-io up to 25.12.4, the advisory lists no patched version: a session with the flash group's download right plus any wildcard file read grant reads any root-readable file, including /etc/shadow and the Wi-Fi keys); CVE-2026-55897 (2026-06-16, luci-app-advanced-reboot's READ ACL gave a shell as root; not installed here); a symlink bypass in the rpcd file plugin; and an open pull request (rpcd #38, opened 2026-08-06, still open 2026-10-02) because rpcd does not enforce session ACLs for non-root local ubus callers. Older: file ACLs bypassed over JSON-RPC when the session id was omitted (issue 8849). My reading: usable as a convenience fence against mistakes, not something to put between a remote path and the device that enforces the segmentation.
Two further costs that are independent of the ACL quality. First, uhttpd would have to listen on a routable address, and rpcd's login endpoint is the same for every account: the root password prompt becomes reachable on that listener too, and OpenWrt's own hardening page warns that LuCI has no brute-force protection ('the password still able to brute-force by flood over ubus'). X6's mitigation, 'LuCI listens on the loopback address only', would no longer be true. Second, it needs a router input rule and, for the household path, a route to a router address.
How uhttpd listens on one extra address only: add one 'list listen_https '<address>:443'' line next to the loopback one in uhttpd.j2 (the address:port form is the one OpenWrt documents and the template already uses), plus one firewall input rule with src zone, src_ip and dest_ip pinned to that address. A second 'config uhttpd' instance on another port is possible but shares the same rpcd and therefore the same logins.

Source: https://openwrt.org/docs/techref/ubus ; https://openwrt.org/docs/guide-user/luci/luci.secure ; https://raw.githubusercontent.com/openwrt/luci/openwrt-25.12/applications/luci-app-acl/Makefile and .../htdocs/luci-static/resources/view/system/acl.js ; https://raw.githubusercontent.com/openwrt/luci/openwrt-25.12/modules/luci-base/root/usr/share/rpcd/acl.d/luci-base.json ; https://raw.githubusercontent.com/openwrt/luci/openwrt-25.12/modules/luci-mod-status/root/usr/share/rpcd/acl.d/luci-mod-status.json ; https://github.com/openwrt/openwrt/security/advisories/GHSA-jw5r-xhf5-2xcq ; https://github.com/openwrt/luci/security/advisories/GHSA-vj96-f37g-37f6 ; https://github.com/openwrt/rpcd/pull/38 ; https://github.com/openwrt/openwrt/issues/8849 ; https://downloads.openwrt.org/releases/25.12.2/packages/aarch64_cortex-a53/luci/ (all read 2026-10-09 through a summarising fetch; that LuCI's login form accepts a non-root user on 25.12 was inferred from the shipped package, not tested)

**3(iii). Exporters on the router and access points feeding Grafana (Phase 9, backlog B3)** (`repository`)

This is the designed answer: prometheus-node-exporter-lua with wifi, netstat, nft-counter and thermal collectors on the three devices, scraped by the in-cluster Prometheus through E7 (the router and access-point parts of E7 are not in the templates yet), shown in Grafana. Two things stand between it and the owner's wish. Timing: Grafana arrives in Phase 9 and gets a route only in Phase 10/11. Placement: Grafana is on the ADMIN listener 10.0.50.201 (section 7), and a CI policy test pins admin-tier routes to that gateway. By the principle 'the household path never reaches the admin listener' the phone cannot see Grafana at all, and the laptop sees it only through the admin path once D1 is widened to 10.0.50.201 in that phase. A household-visible 'home network' dashboard therefore needs a design decision in section 7 (for example a viewer-only route on the household listener behind Authentik); it is not something a firewall row can grant.

Source: docs\ARCHITECTURE.md:357,361,398-404,518; docs\backlog.md B3; docs\components\openwrt.md:40

**3(iv). Lighter options before the monitoring phase, with package names and sizes for OpenWrt 25.12 (aarch64_cortex-a53 feed, release directory 25.12.2; sizes are the .apk download size, not the installed size)** (`primary`)

prometheus-node-exporter-lua 2026.06.05-r1: 6.3 KB. Collectors: -openwrt 1.1, -netstat 1.1, -nft-counters 1.1, -thermal 1.1, -wifi 1.3, -wifi_stations 1.5, -hostapd_stations 2.7, -nat_traffic 1.4, -uci_dhcp_host 1.1, -ethtool 1.5, -mwan3 1.3 KB. Dependencies of the base package: luasocket, lua, uhttpd, uhttpd-mod-lua, libubus-lua; wifi collectors add libiwinfo-lua; hostapd_stations adds hostapd-utils and lua-bit32; nft-counters adds nftables-json and lua-cjson (dependency sizes not read; check with a simulated install on each device, the access points have 6.7 MB). Default configuration: listen_interface 'loopback', listen_port 9100; plain-text metrics, no login, nothing writable. A ucode variant also exists: prometheus-node-exporter-ucode 2024.02.07-r2, 5.8 KB, with -wifi 1.9, -netstat 1.1, -openwrt 0.9, -dnsmasq 0.9, -uci_dhcp_host 0.9 KB; fewer collectors and an older version date. The exporters answer 'is it up, who is associated, how much traffic' as numbers, without root and without a login, but they are not a dashboard: something must scrape and draw. No small ready-made viewer exists in the feed; a status page built from them would be custom code on a container.
Inside LuCI (so each needs a LuCI login, with everything said under 3(ii)): luci-app-statistics 39.9 KB with collectd 94.0 KB and modules (-interface 4.3, -iwinfo 4.5, -cpu 4.5, -memory 3.2, -load 2.6, -rrdtool 11.6, -network 15.5 KB) and rrdtool1 11.1 KB; nlbwmon 79.0 KB with luci-app-nlbwmon 11.8 KB (traffic per host); vnstat2 101.8 KB, vnstati2 46.0 KB (renders images), luci-app-vnstat2 3.7 KB. All fit the router's 25.6 MB easily. netdata is 25,467.5 KB and does not sensibly fit. For reference, the feed's tailscale package is 1.98.3-r1 at 9,676.1 KB.
A shape that exposes nothing on the router: the router and the access points PUSH a small status file (interfaces, leases, associated stations, counters) to the household container on a timer, and the container serves one static page. The router's output policy is already ACCEPT; the cost is one input rule on the container, one forward rule per access point from the management network to the container, and a custom script on three devices, which the repository's rules ask to avoid where a maintained tool exists. The pull alternative (the household container scrapes port 9100 on the router and the access points) needs household -> management rows for the access points, which cuts across 'the household path never reaches the management side' even though the port is read-only.
Home Assistant, once it exists, is the natural household-side viewer for presence and device state, but it reads OpenWrt through a restricted rpcd login as well; that login would then be used from one fixed address at home instead of from the remote path.

Source: https://downloads.openwrt.org/releases/25.12.2/packages/aarch64_cortex-a53/packages/ and .../luci/ ; https://raw.githubusercontent.com/openwrt/packages/openwrt-25.12/utils/prometheus-node-exporter-lua/Makefile ; https://raw.githubusercontent.com/openwrt/packages/openwrt-25.12/utils/prometheus-node-exporter-lua/files/etc/config/prometheus-node-exporter-lua (read 2026-10-09 through a summarising fetch; the push design and the Home Assistant remark are my assessment, not sourced)

**4. Home Assistant timing: what must exist before it can run in the cluster** (`repository`)

By the roadmap rule (no phase starts before the previous gate is recorded) everything from Phase 5 to Phase 13 comes first; applications are Phase 14 and Home Assistant is the first named one (B5, B15). What it technically consumes: Phase 5 (Talos VMs, Kubernetes, Cilium), Phase 6 (enforced default-deny; its egress rule to the ESP32 is a Cilium policy), Phase 7 (Argo CD, the CSI driver for its volume), Phase 8 (cert-manager, OpenBao and External Secrets for its secrets), Phase 10 (the household listener 10.0.50.200 and the trusted certificate; this is what E4 and the remote path point at), Phase 11 (VolSync for the volume backup; Authentik for single sign-on where the application supports it), and Phases 9 and 12 for the definition of done (alerts, logs, runbook). Home Assistant uses its own embedded database by default, so CloudNativePG is not a hard prerequisite (from memory). The router needs the exception B5 names: the ESPHome native API, tcp 6053 to 10.0.60.10, Home Assistant connecting to the device. Because pod traffic leaves with the worker's address, the router row reads 'worker addresses -> 10.0.60.10 tcp 6053' and means 'any pod'; Cilium policy is what narrows it to Home Assistant, as with E6 and E7. In the cluster it would draw on the application budget: about 1907 MiB practical with the worker at 8.5 GiB; Home Assistant's own working set is not published (several hundred MiB by common report; not verified).

Source: docs\ARCHITECTURE.md:268-299,374,747-785; docs\backlog.md B5, B15; https://esphome.io/components/api/

**4. The smallest honest alternative that gives Home Assistant much earlier, and what it costs (laid out, not recommended either way)** (`primary`)

Form A, Home Assistant OS as its own VM. Vendor minimum for a VM: 2 GB RAM and 2 vCPU, UEFI required, a qcow2 image for KVM/Proxmox (the storage figure was not on the page read; 32 GB is the figure I remember, not verified). It is the supported appliance with add-ons and its own updater, which also means it updates itself outside Git and Renovate. Cost on Node 1 with fixed memory as the design demands: 2.0 + 0.2 QEMU overhead = 2.2 GiB. With both remote containers at their ceilings: 15.54 - 1.85 - 11.90 - 0.50 - 2.2 = -0.91 against a required +1.5, so the worker gives up about 2.4 GiB and lands near 6.1 GiB (6246 MiB). The full platform needs 5367 + 560 = 5927 MiB, leaving 319 MiB raw and nothing after the 10 % burst reserve. So: it fits comfortably through Phase 10 (3095 + 560 = 3655 MiB), gets tight at Phase 11 (4767 + 560 = 5327) and does not fit the Phase 12 platform without the pre-agreed levers (control plane to 2.5 GiB, Pocket ID instead of Authentik, Loki deferred, single-node shape). The memory comes back only when Home Assistant moves into the cluster, which the roadmap places after Phase 13, so the squeeze falls in Phases 11 to 13 unless the order is changed or the appliance stays for good and the levers are pulled.
Form B, the Home Assistant container image in a Proxmox container. No QEMU overhead and the limit is a ceiling, not a reservation; with a 1 GiB ceiling: 15.54 - 1.85 - 11.90 - 0.50 - 1.0 = 0.29, the worker gives about 1.2 GiB and lands near 7.3 GiB, leaving about 1540 MiB raw and 790 MiB practical beside the full platform. Costs: no add-ons and no supervisor; running a container engine inside an unprivileged Proxmox container usually wants the keyctl feature, which only root@pam may set (the same wall the plan hit for the tunnel device; nesting alone is allowed to the token), so either a root-run step or Proxmox's newer support for creating a container directly from an OCI image (from memory, a recent tech preview; not verified). It shares the host kernel. The Core and Supervised install methods are no longer offered on the vendor's installation page.
Which VLAN. Servers (VLAN 50): the trunk and the token grant already exist. But the Talos firewall design admits the whole of 10.0.50.0/24 to the Talos API, the Kubernetes API and the kubelet ports on the assumption that the segment holds only cluster nodes; an appliance there becomes a network neighbour of the cluster's host services (all certificate-protected) unless those rules are narrowed to node addresses. Router rows needed: appliance address -> 10.0.60.10 tcp 6053 (B5's exception); trusted -> appliance tcp 8123 (E4 only names 10.0.50.200; 8123 is Home Assistant's default port, from memory); internet tcp 443 is already covered by E5; with household path (a) one more row to tcp 8123, with (b) none. IoT (VLAN 60): no row for the ESPHome API, local discovery works, phones reach it through E9 and it reaches the internet through E8 with no new rule at all; but the trunk must carry VLAN 60 to the hypervisor (lan1:t on vlan60, pve_guest_vlans, one SDN ACL row), the appliance that holds every device credential sits in the least trusted network next to the devices, and it cannot open connections to the trusted network. A VLAN of its own is the cleanest and the most rows.
Backup. A VM is covered by vzdump to the backup server like talos-cp-1, with the known limits: the backup server is a VM on the laptop, started by hand (B32), absent while the owner travels, and no off-site copy exists yet (B25, 'the 3-2-1 rule is not met'). Home Assistant's own encrypted backup is the migration vehicle into the cluster later (configuration and history move; add-ons of the appliance do not exist in the container form; from memory). Before Phase 9 there is no monitoring for it beyond a healthchecks.io ping, and before Phase 10 no TLS and no listener: it would be reached as plain HTTP on its own address, inside the house and inside the tunnel. Each of those is a documented exception against the definition of done, and the provisioning needs a second pool because the only one is named 'talos'.
The trade in one line: an appliance now buys months of use for the owner's stated interest at the price of 1.0 to 2.2 GiB taken from the worker, two or three router rows, a guest that updates itself outside the GitOps path, and a migration later; the cluster path keeps one deployment model and one backup design and delivers nothing the owner can touch until Phase 14.

Source: https://www.home-assistant.io/installation/ ; https://www.home-assistant.io/installation/alternative/ (2 GB RAM, 2 vCPU, UEFI, qcow2; read 2026-10-09 through a summarising fetch); docs\ARCHITECTURE.md:184-212,236-247,268-301; docs\backlog.md B5, B25, B32; infrastructure\ansible\playbooks\group_vars\proxmox.yaml:38; research file line 68-72 (root@pam-only container features). The memory arithmetic is mine from the repository's figures; Home Assistant's real working set, its default port and the OCI route are not verified

**5. Conventions: next free numbers** (`repository`)

Firewall exceptions: E1 to E14 exist, the plan takes E15 to E17, so the household path starts at E18. One E number may cover several rules (E2 and E3 each have three), so 'E18 household container to IoT devices' with one rule per device is in style. Security exceptions: X1 to X26 exist (with X3a, X3b, X8b), the plan takes X27 to X29, next is X30. Likely new X rows: the household path as a standing wide grant (internet on every port from a tailnet-reachable container); the phone as a device with access to the home; if chosen, LuCI on a network address (which rewrites X6); if chosen, an early Home Assistant outside GitOps, monitoring and TLS. Backlog: B1 to B34 used (B18 never assigned), next B35; the plan's 'cloud server' item is still unnumbered. Decision log: next 44. ADRs: 0001 exists; 0002 to 0006 are reserved by its follow-up table, 0005 being 'Administrative access: pinned workstation, optional remote access', which the plan writes in R.0. Household use from away is a different purpose; it either widens 0005's title or takes the next free number, 0007.

Source: docs\phases\phase-r-plan.md:81-87,260; docs\ARCHITECTURE.md:354-372,703-732; docs\backlog.md; docs\adr\0001-platform-stack.md:133-137; research file line 764

**5. Does the zone 'remote' and its rule style extend cleanly to a second source address?** (`repository`)

Syntactically yes: one more Jinja 'set' at the top of firewall.j2 and rules named E<n>-<source>-to-<target> with src 'remote' and their own src_ip; the zone, the Router-DNS entry and the dhcp 'ignore' section are shared. Three things do not extend by themselves. (1) The plan's sentences 'the zone gets name lookups from the router and nothing else' and 'no path from any zone into it except E17' stay true only per address; the zone as a whole now also holds a host with a wide grant to the internet and to the household networks. (2) Two hosts in one zone are layer-2 neighbours on the hypervisor's bridge; the router never sees traffic between them and cannot stop address takeover, so the plan's test 'a second temporary address in the zone reaches nothing' no longer proves separation. It needs either the hypervisor's ipfilter on both containers or a zone per path. (3) The six literal zone loops: if the household path gets its own zone, each loop is a decision (zone list yes, DNS yes, DHCP no, NTP no for a container, ping optional, Force-DNS and Block-DoT yes if the house's DNS policy should cover remote browsing). On pve1 nothing is added for the household address, and the plan's drop row for the rest of 10.0.30.0/24 covers it; a household VLAN of its own should get the same drop row. The plan's wording 'Phase R: remote administration', the title of ADR 0005, D1 and the row R in section 16 all describe one purpose and need rewording.

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\firewall.j2:8-15,22-102,288-308; docs\phases\phase-r-plan.md:89-96,172; infrastructure\ansible\roles\pve_host\tasks\firewall.yaml:39-41

**5. Which tests of the plan need a second vantage point** (`repository`)

(1) 'just test-remote' runs inside remote1 through pct exec. It needs a second run inside the household container with its own expectation table: allowed are the household rows; refused are pve1 on every port, every router address on tcp 22, the access points, 10.0.50.201, 10.0.50.10:6443, 10.0.50.11 and .21:50000, and remote1 itself. The script should take the container and the expectation set as parameters. (2) The 'second temporary address' test is repeated in the household segment, and a new test is added: from the household container, with the admin container's address (or, in option (b), a workstation address) configured, pve1 tcp 22 must stay closed. That test fails by design unless ipfilter or a separate zone is in place, which is its purpose. (3) The phone changes role. Today it is 'the device the policy does not name' and must reach nothing. With a household path it is named: it must reach the household targets and must still be refused on 10.0.10.10, the laptop and both containers. The 'unnamed device' check then needs a third device or a temporary removal of the phone's grant. (4) From the home side: 'any other device on the home networks reaches no port on the container' must be run against the household container too; in option (b) it can only hold through the container's own filter, because trusted devices are its layer-2 neighbours, so the probe has to come from a real trusted client (a phone on the home Wi-Fi). (5) The laptop with both paths up: pve1 still logs 10.0.30.10; household targets leave through the household container; the laptop cannot reach pve1 through the household container; the home/away guard of the tooling still decides correctly. (6) Browsing through home: from the phone on mobile data, the public address seen is the home's and lookups go through the home resolver; from the laptop the same plus a WSL check, because the 2026-10-08 research found that with an exit node the Windows client installs a block-all filter whose Hyper-V/WSL permit is unimplemented, and told the plan not to use an exit node on this laptop. (7) At home: the phone on the home Wi-Fi with Tailscale left on must still reach the ESP32 and the internet normally; travel.ps1 covers the laptop only and the phone has no equivalent. (8) 'just test-fences' again with each path connected.

Source: docs\phases\phase-r-plan.md:162-176; docs\research\2026-10-08-remote-access-research.md:467-471,737-754

## Threat model of a household path beside the administration path

### Recommendation

Build the household path as a second gateway in its own VLAN and its own router zone, right after the admin path has passed its gate, and keep the admin path exactly as planned.

1. Two gateways, two VLANs, two zones. A different address inside VLAN 30 is not enough: on one segment the household container could reach the admin container directly and could take over 10.0.30.10, which the router and pve1 trust. With separate VLANs the router sees the difference and nothing at Tailscale can change it.

2. Household rules name devices and ports. Not the trusted zone and not the IoT zone as a whole, and never 192.168.1.196, .197 or .53. The workstation's trusted addresses live in the trusted network, so a wide rule there is the one route by which the household path could touch the admin side.

3. Add a layer outside the guests: the Proxmox firewall on each gateway's network device, with an inbound drop, an outbound allow-list and the address filter. Root inside a container cannot remove it. The role does not manage per-guest firewall files yet.

4. The exit node goes on the household gateway only. Say plainly in the plan that this gateway can reach the whole internet, and that 'reaches only X' is a claim about the admin container. Its form (container or small VM) stays open until the lab shows whether a userspace exit node works.

5. No LuCI from away through the household path. The network view on the phone comes from the monitoring phase, read-only, on the household listener.

6. The phone is a client and not a signer, and the GitHub second factor must work without it. This changes D4 and must be decided before R.3.

7. Close the one 'never' that a single layer holds, 'a household client never uses the admin gateway'. Two cheap measures: the admin container runs only while the laptop travels (started by 'travel.ps1 -Away', stopped by '-Home'), so at all other times the router has nothing to admit; and pve1's second factor does not live on the phone alone. Both are proposals for the owner, not part of the reviewed plan.

8. In the admin phase's steps R.5 and R.6, also lay the second VLAN and an empty zone, so the household phase changes firewall rules only and the household's Wi-Fi is interrupted once, not twice.

### Risks

- The phone becomes a daily tailnet client. Only the Tailscale policy keeps it off the admin gateway; the admin container and the router see one source address for every device. An account takeover or a policy mistake puts the phone at pve1's login pages.
- A stolen unlocked phone operates every device in its grant that has no login (the ESP32, a printer) and Home Assistant through its saved session. If web OTA is enabled without a password on the ESP32, it can be reflashed into a lasting implant in the IoT network.
- If the GitHub second factor lives only on the phone, losing the phone also removes the owner's ability to cut it off until recovery codes are found.
- Two exposed containers share the hypervisor's kernel. A kernel escape from either is root on pve1 and so on the other. The exit node makes the household one the busier of the two.
- A household rule to the whole trusted network would give a remote route to a segment in which the workstation's trusted addresses can be imitated while the laptop travels (exception X9). The targets behind those addresses still need keys, certificates or password plus TOTP.
- Exit-node traffic leaves under the household's ISP identity. Abuse through a compromised client or gateway lands on the home connection, and neither Tailscale's free plan nor the router keeps a log that would show which device did it.
- The household listener will be reachable from away. That an admin hostname is not served there rests on Traefik's listener binding, which the design still marks as an assumption (Phase 10 gate).
- Home Assistant's 'trusted networks' login skips the password and the second factor. If the gateway's or the proxy's address were ever listed there, the path from away would need no login at all.
- A second container at a 0.25 GiB ceiling takes the paper headroom on Node 1 from 1.54 to 1.29 GiB, below the standing gate of 1.5 GiB. A VM for the exit node would cost more and shrink the worker.
- A userspace exit node on Linux without root is not confirmed by any Tailscale page I read. If it fails, the exit node needs a VM or is dropped.
- On the laptop an active exit node is reported to block WSL traffic, so browsing through home and an administration session cannot run at the same time.
- Phones have no travel script. At home with Tailscale left on, traffic to home addresses that are advertised as routes may go through the tunnel and arrive from the gateway's address, slowly; and 192.168.1.0/24 is a common range on foreign Wi-Fi networks.
- A read-only LuCI login is not a supported security boundary, and a broad read right probably includes the Wi-Fi keys and the full firewall configuration.
- Web pages were read through a summarising tool. Every quoted sentence, flag and default must be read again at the source and on the pinned version before it enters a plan, role or runbook.

### Open points

- Lab: does tailscaled as an unprivileged user in userspace mode work as an exit node on Linux (TCP, UDP, name lookups for clients), and does it refuse to forward exit traffic to 10.0.0.0/8 and 192.168.0.0/16 even when the policy is widened to allow it?
- Lab: with a grant widened on purpose, confirm that the household gateway cannot reach 10.0.10.10, 10.0.30.10, any router address on tcp 22, or 10.0.50.201, with the failure shown at the container's filter, at the Proxmox guest firewall and at the router separately.
- Lab: can root inside an unprivileged container change its VLAN tag or send frames with another tag? Expected no, not verified.
- Lab: does the Proxmox per-guest firewall (classic implementation) work on a container's interface on the VLAN-aware bridge, can the scoped token set the firewall flag, and does ipfilter stop a second address?
- Lab: node signing enabled from the command line with the laptop as the only signer; what the console shows; recovery with a disablement secret. Only if H4 is chosen as recommended.
- Not verified: whether the Tailscale phone clients have an app lock, whether they accept advertised routes by default, and how they treat a route for 192.168.1.0/24 when the phone is itself on a network with that range, at home or abroad.
- Not verified: whether 'via' in grants is accepted on the Personal plan (already an R.2 check); the household path needs it to tie the exit node and the routes to one tag.
- Not verified: the Tailscale sharing page says a machine cannot be shared 'with a tag'; whether a tagged gateway can be shared OUT by an account holder should be read again at the source. Under node signing the recipient's devices need a signature either way.
- Owner input: which phone (iPhone or Android), where the GitHub second factor and the pve1 TOTP live, and whether a hardware key exists.
- Owner input: what 'reach family devices' means in ports (file shares, remote desktop, a camera, printing). Without that list rule H1 cannot be written.
- Owner input: the ESP32's ESPHome configuration: is 'auth:' set on the web server and is web OTA enabled? The printer's model and whether its web page has a password.
- Design, monitoring phase: how a read-only network view is published on the household listener when Grafana is planned on the admin listener and CI ties admin routes to it.
- Design: Home Assistant's exception from the servers network to the IoT network (backlog B5) and the removal of the raw IoT rows from the household path once it exists.
- Not researched: the legal position in India of running an exit node on a home connection, and the ISP's terms.
- Not available: the reviewers' individual findings on the plan's draft; pull request 29 gives only the count and the one blocker.
- The VLAN number, subnet and address of the household gateway (31, 10.0.31.0/24, .10 in this report) are a proposal to be confirmed against the live router and the private inventory before anything is written.

### Findings

**1a. Separation rule: what the household path MAY reach (addresses, ports)** (`repository`)

Proposal, not built. The household path needs its own gateway in its own VLAN and fw4 zone, for example a container 'home1' at 10.0.31.10 in VLAN 31, zone 'homeremote' (number and address are a proposal: VLAN 31 is unused in the table of ARCHITECTURE section 6; the owner or plan picks it). Allowed, each as one commented router rule with src_ip = that one address:
(a) 10.0.50.200 tcp 443, the household listener, from the phase that builds it. This is where Home Assistant will be, and later a read-only network view.
(b) IoT, by named device and port, not the zone-wide E9: today 10.0.60.10 tcp 80 (ESP32 page). The printer 10.0.60.182 only if the owner really prints or scans from away.
(c) Trusted network: named family devices and named ports only. Never 192.168.1.196 and .197 (the workstation), never 192.168.1.53 (the router).
(d) Internet, all ports, only if the exit node is chosen (see 4). The rule should be 'dest wan' and should additionally refuse private destination ranges on the WAN side, because the ISP side holds 172.16.131.128/26 and 192.168.199.x (ARCHITECTURE line 325).
(e) Name lookups at the router's address in that zone.
The admin path stays exactly as planned: 10.0.30.10 -> 10.0.10.10 tcp 22, 8006 (E15).

Source: docs\ARCHITECTURE.md lines 313-372 ; infrastructure\ansible\roles\openwrt_config\templates\router-m30\firewall.j2 lines 41-55, 203-210 ; docs\phases\phase-r-plan.md lines 73-96

**1b. What the household path must NEVER reach, and which layer enforces each 'never'** (`primary`)

Never: pve1 10.0.10.10 on any port; the whole of 10.0.10.0/24 (access points .2, .3); tcp 22, 80, 443 on ANY router address (192.168.1.53, 10.0.10.1, 10.0.30.1, 10.0.50.1, 10.0.60.1 and the new zone's own .1); the admin gateway 10.0.30.10 and all of 10.0.30.0/24; 10.0.50.10:6443, 10.0.50.11 and .21:50000, every node address, and 10.0.50.201 on any port; the workstation 192.168.1.196/.197 on any port (it holds the forward to the backup server on 8007); the direct link 10.0.99.0/29.
Layers:
1. Tailscale policy: grants for the household tag name only (a) to (d); deny tests for every 'never'; autoApprovers ties 10.0.10.10/32 to the admin tag only. Falls with an account takeover.
2. Node side, not changeable from the console: the household gateway advertises only household routes (a route must be advertised by the device itself and approved; research line 228). If it is an exit node, Tailscale's own code removes 10/8, 172.16/12, 192.168/16, link-local and the Tailscale range from the default route it serves ('guest wifi' comment, removeFromDefaultRoute), so the exit node does not forward to home addresses.
3. The container's own nftables output allow-list, for the Tailscale user only. Falls with root in the container.
4. Optional and recommended as a new layer: the Proxmox firewall on the container's network device (a <vmid>.fw file with policy_in DROP, an outbound allow-list and ipfilter). It runs in the host kernel, outside the guest, so root in the container cannot remove it. The Proxmox documentation (9.2.13) says the guest file applies to VMs and containers and that each network device has its own firewall flag. The role manages only cluster.fw and host.fw today (research line 789).
5. Router: the new zone has input and forward REJECT, no rule towards mgmt, remote or the admin addresses in servers, and no input rule for tcp 22. In fw4 a packet to any router address is judged by the zone it arrived in (research line 659), so router SSH is closed on every address at once. LuCI listens on 127.0.0.1 only (uhttpd.j2 lines 4-5).
6. Each target: pve1's host firewall admits .196, .197 and 10.0.30.10 only (add a drop row for the new subnet, as for X10); access points admit the workstation only; SSH is key-only; Talos and Kubernetes APIs need client certificates; the admin listener sits behind Authentik with MFA.
Every 'never' above has layers 1, 3, 5 and 6 behind it, PROVIDED the household gateway is in its own VLAN and zone.

Source: docs\research\2026-10-08-remote-access-research.md lines 228, 659, 686, 789 ; infrastructure\ansible\roles\openwrt_config\templates\router-m30\uhttpd.j2 ; infrastructure\ansible\roles\pve_host\tasks\firewall.yaml ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnlocal/local.go (read through a summarising tool, characters 100000-200000) ; https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html (9.2.13)

**1c. Which 'never' is enforced by only ONE layer** (`repository`)

Six cases. The first is the one that matters most for the admin path.
1. 'A household client (the phone, later a family device) never uses the ADMIN gateway.' Only the Tailscale policy enforces it. The admin container's filter and the router see one source, 10.0.30.10, for every tailnet device (the plan's exception X29). After an account takeover or a policy mistake, the phone stands at pve1's login pages. Behind that are only pve1's own logins: the SSH key is not on the phone, but the TOTP generator for the web interface probably is. This exists in the current plan from the moment the phone is enrolled (R.3); the household path makes the phone a daily, always-connected client, so the case becomes more likely to be exercised.
2. 'An admin hostname is never served through the household listener 10.0.50.200.' Only Traefik's listener binding enforces it, and ARCHITECTURE line 403 marks that as an assumption with a Phase 10 gate. Every network layer allows the household gateway to reach .200:443. Authentik's API is also routed there (line 401).
3. 'A compromise of the household gateway never becomes root on pve1.' In the container form the shared kernel is the only boundary (the plan's D2 cost). A VM would put the hypervisor boundary there instead.
4. 'Only the owner's devices operate the ESP32 or the printer.' Those targets have no login, so possession of an enrolled, unlocked device is the whole authentication, and only the Tailscale policy tells devices apart.
5. 'Only the owner's devices use the exit node.' Tailscale policy and node signing only; the router cannot tell exit traffic from anything else.
6. Conditional: if the rule to the trusted network were zone-wide, 'never the workstation' would rest on Windows Firewall alone. With named devices it has three layers.
A seventh appears if both gateways shared VLAN 30: 'household gateway never reaches the admin gateway' would rest on the admin container's own filter alone, and the household container could take the address 10.0.30.10 on the shared segment and inherit E15. That is the reason for a separate VLAN (see 3a).

Source: docs\phases\phase-r-plan.md lines 23-32, 39, 237 ; docs\ARCHITECTURE.md lines 401-403

**2a. Lost phone: what it reaches, locked and unlocked** (`primary`)

Locked: nothing, short of a break of the phone's own lock. The node key sits in the phone's encrypted storage.
Unlocked (snatched in use): I found no app lock in the Tailscale mobile client (not verified; from memory there is none). The thief then has, with no further login:
- the ESP32 page at 10.0.60.10. ESPHome's web server has authentication off unless 'auth:' is set, and its documentation (2026.9.1) warns that with web OTA enabled and no auth 'anyone who can reach the device ... can upload firmware'. A flashed ESP32 is a lasting implant in the IoT network, which may reach the internet (E8).
- the printer's web page, if it is in the path (usually no login; general knowledge, not verified for this model).
- Home Assistant, in practice WITHOUT its login: the companion app and the browser keep a long-lived session. Home Assistant's own login protects against a stranger's device, not against the owner's unlocked one (reasoning; token lifetime not verified).
- named family devices on the trusted network, as far as those devices accept a connection without credentials.
- the exit node: browsing from the home address.
- LuCI only if it was exposed, and then only the login page unless the root password is saved on the phone.
Not reachable: pve1, router SSH, access points, admin listener, cluster APIs. The household gateway's address has no router rule to any of them.
The step up: if the phone's browser holds a live GitHub session, the thief opens the Tailscale console, rewrites the policy and reaches pve1's login pages through the ADMIN gateway (case 1 of 1c). The router does not stop that, because E15 admits 10.0.30.10 whoever is behind it.

Source: https://esphome.io/components/web_server/ ; https://www.home-assistant.io/docs/authentication/providers/ ; docs\phases\phase-r-plan.md lines 85, 190-199

**2b. How the owner cuts a lost phone off, and from where** (`repository`)

From any browser, in this order:
1. Tailscale console: remove the household gateway. The path is closed for every device, and the gateway can only return through a login at home. If a GitHub session may have been on the phone, remove the admin gateway too.
2. GitHub: change the password, end all sessions.
3. Remove the phone from the tailnet ('The device will immediately lose connection to all resources', research line 370).
4. Remote-wipe the phone through its vendor account.
5. Later, at home or over the path: revoke the phone's session in Home Assistant. The ESP32 and the printer hold nothing to revoke.
6. If the phone was a signer: 'tailscale lock remove' on the laptop, command line only.
Precondition that the plan does not state: the owner must be able to log in to GitHub WITHOUT the phone. If the second factor is an authenticator app on that phone, steps 1 to 3 need the recovery codes or a second factor on another device (a hardware key or a passkey on the laptop). The plan asks for 'stored recovery codes'; it should say where they are reachable when the phone is gone and the laptop is at home.
There is no stop that works without the account. A family member at home has no way to stop a container on pve1.

Source: docs\research\2026-10-08-remote-access-research.md lines 368-372 ; docs\phases\phase-r-plan.md lines 54, 186-199

**2c. Is it wise for the phone to be both a household client and a signer? The alternative** (`primary`)

It is acceptable but it stacks three roles on the device most likely to be lost: daily client, signing key, and probably the GitHub second factor and the pve1 TOTP.
What the signing key adds for a thief with the unlocked phone and a GitHub session: he can enrol and sign his own devices. They stay signed after the phone is removed, until the laptop withdraws the phone's key (command line, laptop only). Removing both gateways neutralises this at once, because signed rogue devices then have nothing to reach.
What the phone-as-signer buys in the current plan is small: the plan's own lost-laptop procedure already ends with a disablement secret, because 'a phone can sign a device but cannot withdraw a signing key' (D4). It buys signing a replacement laptop on the road, and it satisfies the console wizard's demand for two signers.
Alternatives:
(A) Phone is a client only; the laptop is the single signer, enabled from the command line (research line 240 says the CLI needs only the key of the node that runs init; the wizard asks for two). Recovery from a lost or dead laptop is the disablement secret, as already planned. Fewer keys outside the house, no new guest. To verify in the lab.
(B) Phone is a client only; the second signer is a small signing-only container at home that advertises nothing, is named in no grant and is kept stopped except when something must be signed. It can also withdraw a lost laptop's key without burning a disablement secret. Costs one more guest and depends on a check the plan already lists as open ('a tagged device can sign').
(C) Keep D4 as written (iPhone signs). Honest cost: a stolen unlocked phone with a GitHub session controls the tailnet until the owner reaches a browser.
I recommend (A), with (B) if the owner wants a second signer. Either way this changes D4 of the reviewed plan, so it is the owner's decision.

Source: docs\phases\phase-r-plan.md lines 41, 186-199 ; docs\research\2026-10-08-remote-access-research.md lines 238-252, 370 ; https://tailscale.com/kb/1226/tailnet-lock

**2d. A family member's device later** (`primary`)

Do not log it in with the owner's GitHub account: the owner's session would then live on the least managed device. Invite the person as a second user (the Personal plan allows up to 6 users per the repository's research of 2026-10-08; user approval is on in the plan). Under node signing the owner must sign that device. Give it a narrower grant than the owner's phone: the household listener only (Home Assistant with that person's own login), no raw IoT addresses, no trusted-network devices, the exit node only if asked. It is never a signer and never named in an admin grant. Node sharing is not a substitute: 'Shared machines do not advertise subnets to the tailnets they're shared into', so a device in another tailnet cannot use the home routes.
Each added client is another device whose unlocked loss opens whatever its grant names; for targets without a login the grant is the only lock.

Source: https://tailscale.com/kb/1084/sharing ; docs\research\2026-10-08-remote-access-research.md line 210

**3a. Pivot: compromised household gateway -> admin gateway. How the plan and the hypervisor's bridge handle traffic inside one VLAN, and what Proxmox offers** (`primary`)

Today's plan has one guest in VLAN 30, so the question never arose. vmbr0 is one VLAN-aware bridge (interfaces.j2 lines 12-19) with no isolation between guest ports; two guests with the same tag exchange frames directly and the router never sees them (standard bridge behaviour; from general knowledge, not read in a source today). The plan's protection inside the zone is the container's own filter only, and research line 789 records that a per-guest Proxmox firewall is undefined.
If the household gateway were put in VLAN 30 beside remote1:
- it reaches remote1 directly; only remote1's own nftables input drop stands between them;
- worse, it can configure 10.0.30.10 as its own address while remote1 is down, or contest it by ARP, and the router's E15 and pve1's firewall row would then admit it to pve1 tcp 22 and 8006. 'Different source addresses' is not a separation when both sit on one segment.
What Proxmox offers (documentation 9.2.13):
1. Separate VLANs. A second tag on the trunk, its own fw4 zone, its own SDN.Use row for the token. Traffic between the gateways must then pass the router, where zones deny by default. The tag is set on the host side of the container's interface, outside the guest (reasoning, not verified). This is the only option that also lets the router give the two paths different rights without trusting an address. Recommended.
2. Firewall on the guest's network device: per-device flag, per-guest file with policy_in, policy_out, ipfilter and macfilter; applies to containers. Good as a second layer (it stops spoofing and enforces the outbound list from outside the guest), not as the only one. The nftables-based proxmox-firewall is still 'tech preview ... not suited for production use', so this means the classic implementation.
3. Bridge port isolation exists only as the SDN VNet option 'Isolate Ports' ('guests can only send traffic to non-isolated bridge-ports, which is the bridge itself'; 'Port isolation is local to each host'). The plan attaches guests to vmbr0 with a tag, not to a VNet, and hook scripts are root-only, so this is not available without introducing SDN VNets. Not recommended here.

Source: infrastructure\ansible\roles\pve_host\templates\interfaces.j2 ; docs\research\2026-10-08-remote-access-research.md lines 698-704, 789 ; https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html ; https://pve.proxmox.com/pve-docs/chapter-pvesdn.html (first 100000 characters read)

**3b. Pivot: compromised household gateway -> hypervisor, trusted devices, IoT devices** (`repository`)

Hypervisor, by network: no path. pve1 has no address in the guest VLANs, does not forward (ip_forward 0), and a packet from the gateway to 10.0.10.10 must cross the router, where the household zone has no rule. pve1's firewall drops by default; add an explicit drop row for the new subnet as the plan does for 10.0.30.0/24.
Hypervisor, by kernel: the one real exposure. The chain is a flaw in tailscaled (unprivileged user), then root in the unprivileged container, then a kernel escape. Root on pve1 owns everything, including the admin container. A second exposed container doubles the number of such starting points; the exit node makes this one busier. A small VM removes the shared kernel at about 0.4 to 0.6 GiB (research line 990).
Trusted network: exactly the named devices and ports of the router rule. This is the pivot that touches the admin side indirectly: the workstation's two addresses live in the trusted network and E1 to E3 trust those addresses (exception X9, 'spoofable inside VLAN 20'). A family PC taken over through the household path could claim .196 while the laptop is travelling and so reach the router's SSH port, pve1 and the cluster APIs at network level. Every one of those still needs a key, a certificate or password plus TOTP (ARCHITECTURE line 376), and any infected family PC has that position today. The household path adds a remote way to get there. This is the reason to name devices and ports instead of opening the trusted zone, and to keep .196, .197 and .53 out.
IoT devices: the named ones, with no login in the way. From the gateway the ESP32 can be operated and, if web OTA is on without auth, reflashed.

Source: docs\ARCHITECTURE.md lines 327, 376 ; infrastructure\ansible\roles\pve_host\tasks\firewall.yaml ; docs\research\2026-10-08-remote-access-research.md lines 694, 973-990

**3c. Compromised IoT device today versus after the household path exists: does the path add anything?** (`repository`)

For the IoT device's own rights: nothing. Today the IoT zone may open connections to the internet (E8) and to the router for DHCP, DNS and NTP, and to nothing else; it never initiates to the trusted network. After the household path the same holds, provided the new zone gets no rule FROM iot. The gateway opens connections to IoT devices; replies return through connection tracking only. In userspace mode tailscaled ends each TCP connection and opens a new one, so a hostile IoT device talks to the container's TCP stack and, at application level, to the remote phone's browser, which is the same exposure the phone has at home through E9.
What the path does add is on the other side: the set of places from which IoT devices can be operated grows from 'inside the house, on the main Wi-Fi' to 'wherever an enrolled device is'. For devices with no login that is the real change.

Source: docs\ARCHITECTURE.md lines 350, 362-363 ; infrastructure\ansible\roles\openwrt_config\templates\router-m30\firewall.j2 lines 49-55 ; https://tailscale.com/kb/1177/kernel-vs-userspace-routers

**4a. Exit node: what it needs technically, and what is not settled** (`primary`)

- Policy: 'To permit exit node use, add a grant or ACL whose dst is autogroup:internet'; the documented example restricts it to one router with via and a tag. Approval can be automatic through autoApprovers.exitNode for the tag. Whether 'via' is accepted on the free plan is already an open check of the plan (R.2).
- Form of the gateway: NOT settled. The exit-node page says 'You must enable IP forwarding to advertise a Linux device as an exit node', which is kernel mode, and kernel mode in a container needs a tunnel device that only root@pam can hand over (the reason the admin plan chose userspace mode). The same page says Android, macOS and Windows exit nodes are 'limited to userspace routing', and the source's userspace router handles 'incoming traffic destined to non-local IPs', so a userspace exit node on Linux probably works. No Tailscale page I read states it for Linux without root. Lab check before any promise. If it fails, the exit node needs a small VM.
- Userspace mode carries TCP and UDP and only reconstructed ping; performance is rated 'acceptable'. Both ends are behind provider NAT, so browsing will probably be relayed through Tailscale's servers and slow unless the UDP rows are opened.
- Outbound rule: all TCP and UDP ports to the internet. The plan's E16 (tcp 443 only) cannot serve an exit node.
- Home addresses stay closed to exit traffic by Tailscale's own code on the node: the default route it serves excludes 10/8, 172.16/12, 192.168/16 and the Tailscale range unless those are advertised as routes. That is a node-side fence an account takeover cannot lift.
- 'When Tailscale operates as an exit node, it runs a DNS server for peers', so clients resolve through the container's resolver, the home router.
- Conflict with the admin path on the laptop: the research found that with an exit node active the Windows client installs a block-all filter whose WSL permit is not implemented. Browsing through home and administering from WSL cannot be on at the same moment on the laptop. Start with the phone.

Source: https://tailscale.com/kb/1103/exit-nodes ; https://tailscale.com/docs/features/access-control/grants/grants-via ; https://tailscale.com/docs/reference/syntax/policy-file ; https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/netstack/netstack.go ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnlocal/local.go ; docs\research\2026-10-08-remote-access-research.md lines 68-72, 469

**4b. Exit node: abuse scenarios, exposure of the home address, and the claim 'the container can reach only X'** (`primary`)

The claim: it survives for the admin container only if the exit node is a different container in a different zone. For the household gateway the honest sentence becomes 'named home targets, plus the whole internet on every port'. That is the standing of any phone on the home Wi-Fi (trusted -> wan is open), so it is no new right for the household, but it is a wider foothold than the admin container's tcp 443: a compromised gateway can send mail, scan and join peer-to-peer networks from the home address.
Who can use it:
- another member of the tailnet: only a source the grant names. There is one user today.
- an outsider after a GitHub takeover: he can rewrite the grant, but his device needs a signature. A shared-out node under node signing also requires that 'the user who accepts the share invite needs to have their nodes signed'. So takeover alone is not enough; takeover plus a signing key is. Node signing therefore matters more once an exit node exists.
- the owner's own phone or laptop when malware is on it: fully. Nothing at home can tell that traffic from the owner's.
Exposure: everything leaves under the household's ISP identity (shared public address under carrier-grade NAT, attributed to the subscriber in the provider's records; the legal side for India was not researched). Complaints, blocks and reputation damage land on the home connection and affect the family. The owner would have no evidence afterwards: 'Destination logging is available for the Premium and Enterprise plans', and the router keeps its log in memory only (ARCHITECTURE line 362). This extends the plan's exception X29. The Personal plan is for non-commercial use.

Source: https://tailscale.com/kb/1103/exit-nodes ; https://tailscale.com/kb/1226/tailnet-lock ; https://tailscale.com/kb/1084/sharing ; docs\phases\phase-r-plan.md lines 235-237

**5. LuCI or a router dashboard from away, graded by what a thief with the unlocked phone or laptop gets** (`primary`)

Worst to best.
Grade F, full control: LuCI with the root login reachable through the household path. It needs uhttpd on a routable address and a router input rule. A thief gets the login page, and with a saved password the device that enforces every 'never' in this design: LuCI as root is equal to a root shell. It also puts a web server on the enforcement device in reach of the more exposed gateway. It breaks the design principle outright. Never.
Grade D: LuCI as today (loopback, inside root SSH), reached through the ADMIN path by adding router SSH to E15. This is the alternative the plan's D1 already describes and advises against: it puts root SSH on the router within reach of the remote endpoint, laptop only. A thief with the unlocked laptop and an open session gets the router.
Grade C, read-only but it maps the network: a second LuCI login with read rights only. OpenWrt's rpcd supports logins with 'list read' and 'list write' per account, and root is simply read '*' and write '*'. Costs: LuCI is not built as a multi-user boundary (forum-level evidence only); a read of '*' includes the configuration, which holds the firewall rules, the client list and probably the Wi-Fi keys (not verified; a narrower list is possible and is work); and it still needs the listener and the input rule of grade F.
Grade A, nothing sensitive: the dashboard the design already plans. Router and access-point exporters are scraped by the cluster (E7, backlog B3), and a read-only view is published on the HOUSEHOLD listener 10.0.50.200 behind Authentik with MFA. The router gets no new listener towards the household gateway. A thief with the unlocked phone gets a login prompt, or with a live session traffic graphs and device counts, and can change nothing. Two costs: it does not exist until the monitoring phase, and Grafana is planned on the admin listener, with a CI rule that admin routes attach only there (ARCHITECTURE line 404), so a household-side read-only view is a design decision for that phase.
Until then: nothing from the phone. The Tailscale console and the health check already show whether the gateways are alive.

Source: infrastructure\ansible\roles\openwrt_config\templates\router-m30\uhttpd.j2 ; docs\ARCHITECTURE.md lines 355, 361, 389, 401-404 ; docs\phases\phase-r-plan.md line 38 ; https://openwrt.org/docs/techref/ubus ; https://forum.openwrt.org/t/luci-create-readonly-or-unprivileged-user/65543/2 (secondary)

**6a. The decisions the owner must make for the household path, in the form of the plan's decision table** (`repository`)

H1. What the household path reaches at home.
Recommended: named devices and ports only. Now: the ESP32 page. Later: the household listener when Home Assistant exists; after that the raw IoT rows are removed so every remote action passes Home Assistant's login. Family devices one by one, each with its port. Never the workstation's addresses, never the router. Before the ESP32 is in the path: set 'auth:' on its web server and keep web OTA off.
Alternative and cost: the whole IoT and trusted networks, like at home (E9). Less to maintain, but a lost unlocked phone then operates every device without a login, and a remote path reaches the network in which the workstation's trusted addresses can be imitated.

H2. Browsing through the home connection (exit node).
Recommended: yes, on the household gateway only, never on the admin container; phone first; the grant names the owner's devices. Cost: that gateway's outbound rule opens to every port, so 'reaches only X' holds for the admin container alone; anything done through it is attributed to the household, with no log to prove otherwise; probably slow; and the form is open until the lab shows that a userspace exit node works. If it does not, the choice is a small VM (about 0.4 to 0.6 GiB, taken from the worker) or no exit node.
Alternative: no exit node. The household gateway then keeps a narrow outbound rule like the admin one.

H3. Seeing the home network from away.
Recommended: nothing through the household path until the monitoring phase publishes a read-only view on the household listener. Never LuCI on the household path. Cost: no dashboard on the phone for several phases.
Alternatives: a read-only LuCI login (maps the network to whoever holds the phone, adds a web listener on the router); or router SSH through the admin path, laptop only (the D1 alternative).

H4. The phone's role, and other people's devices.
Recommended: the phone is a household client and not a signer; the laptop signs alone, with the disablement secrets as the way out (or a signing-only container at home if a second signer is wanted). The GitHub second factor must be usable without the phone. Family members join as invited users with a narrower grant. Cost: a replacement laptop cannot be signed on the road; one more lab check; D4 of the admin plan changes.
Alternative: keep D4 (an iPhone signs). Cost: an unlocked stolen phone with a GitHub session controls the tailnet until the owner reaches a browser.

Source: Synthesis of the findings above; form taken from docs\phases\phase-r-plan.md lines 34-48

**6b. Same phase as the admin path, or right after it?** (`repository`)

Right after it, as its own gate, with one exception: lay the plumbing in the admin phase's two disruptive steps.
Reasons to build it second:
1. The admin plan already carries 11 decisions and 12 points that only the lab can settle. The household path depends on four of them: userspace mode works as an unprivileged user, the token can create a container on a VLAN and nothing wider, node signing behaves as documented, and the policy root works. Built second, it reuses proven parts. Built together, a failure cannot be assigned to one path.
2. The admin gate's cleanest test is 'the phone, which the policy does not name, reaches nothing'. It should be recorded before the phone gets any grant.
3. Memory. The admin container's 0.25 GiB ceiling leaves 1.54 GiB against a gate of 1.5. A second container at the same ceiling leaves 1.29 on paper. The admin phase's memory drill produces the measured number that decides whether two small limits fit or the worker shrinks.
4. The targets that give the household path most of its value do not exist yet: Home Assistant is Phase 14 (backlog B5) and the dashboard belongs to the monitoring phase. Today the path would serve one ESP32 page, perhaps a printer, and the exit node.
The cost of a second visit is one more router network restart (Wi-Fi drops for a few seconds) and one more guarded bridge change on pve1. That cost can be removed: in R.5 and R.6 also add the second VLAN to the trunk and the bridge, and the empty zone with no rules, documented as reserved. The token gets no right to attach a guest to it until the household phase. The household phase then changes firewall rules only, which reloads the firewall without restarting the network.
One change belongs in the admin phase regardless: decide H4 before R.3 and R.4, because it changes who signs.

Source: docs\phases\phase-r-plan.md lines 63-71, 141-160, 273-283, 298-315 ; docs\backlog.md lines 11, 22 ; docs\research\2026-10-08-remote-access-research.md lines 714, 726

**Were the red-team findings on the plan's draft available?** (`repository`)

Only in summary. Pull request 29 says the draft was reviewed from three views (an attacker's, feasibility against the repository, consistency with the approved design), a fourth reviewer filtered the result, 25 findings held, and one was a blocker: 'the lost-laptop procedure could not be carried out as first written'. The individual findings are not recorded in the pull request or in the repository; they are worked into the plan text. I could therefore use the plan's 'Lost laptop' and 'Risks' sections, not the reviewers' own wording.

Source: GitHub pull request 29 of the homelab-infra repository (body read with gh through WSL; no comments or reviews attached) ; docs\phases\phase-r-plan.md line 7

