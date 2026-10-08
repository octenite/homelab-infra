# Research: remote administration with Tailscale (2026-10-08)

Input to `docs/phases/phase-r-plan.md`. Five researchers each took one question, read-only, on 2026-10-08. Each finding says how it was verified: `primary` (vendor documentation, source code, package index), `secondary`, `repository` (this repository), or `not-verified`. Web pages were read through a tool that summarises, so quoted sentences must be read again at the source before they are copied anywhere. The open points of each section are the checks the plan carries into the lab.

This file is a record. It is not maintained: where it and a later document disagree, the later document wins.

## The subnet router on a small Linux guest

### Recommendation

Build the subnet router as an unprivileged Debian 13 container in VLAN 30 with one fixed address, and run tailscaled in userspace networking mode first; fall back to kernel mode only if the lab test fails.

Why userspace mode first: Proxmox allows TUN passthrough (dev0) and the keyctl feature to root@pam only, so kernel mode in a container cannot be provisioned by the existing OpenTofu token. Userspace mode needs no TUN device, no forwarding sysctl, no firewall rules written by tailscaled and no capabilities, and every Phase R target is TCP, which is what that mode supports. The trade is that Tailscale's own comparison rates it 'acceptable' in performance and less mature than kernel mode. If it fails the test, the fallbacks are, in order: a small VM in kernel mode (no host exception, more RAM), or the container in kernel mode with a documented root step on the host for dev0.

Settings either way:
- Keep source NAT at its default. Targets and the router's fw4 then see exactly one source, the container's address in 10.0.30.0/24, and no route for 100.64.0.0/10 is needed at home. Do not use --snat-subnet-routes=false.
- Advertise the targets as /32 routes; approve them through autoApprovers for the router's tag; write grants that name each target address and port and never the router itself.
- Do not use --shields-up (it stops routing). Do not enable Tailscale SSH. Do not make this node a tailnet lock signing node.
- Authenticate with a one-off, tagged, short-lived auth key that is not pre-signed, and sign the node from the laptop. Leave key expiry disabled on this tagged node and enforce expiry on the owner's devices; record that as a stated deviation from 'key expiry' in the design.
- Add an nftables table owned by the role: default drop, allow only the listed target address and port pairs (output chain in userspace mode, forward chain in kernel mode), drop everything arriving for the node itself from the tailnet. Never 'flush ruleset'.
- Egress from the remote zone to the internet: DNS, TCP 443, UDP 3478, UDP from 41641. Leave TCP 80 closed unless the test shows a need.
- Pin the package: vendor apt repository with the signed-by keyring, exact version in an Ansible variable, apt preferences pin, client auto-update off. 1.104.1 is one day old; pinning 1.102.5 for the first build and moving to 1.104.x after a week is the more conservative choice.
- Configure with 'tailscale up' and the full flag set from Ansible rather than the alpha config file.
- Give the container a 256 MiB ceiling to start, measure for a week, then decide on 128 MiB.
- Include the container in the Proxmox Backup Server job so a restore keeps the node identity; document the from-scratch path (new key, sign, done) as the alternative.

### Risks

- Every web page was read through a fetch tool that summarises; quotes are as that tool returned them. Flag names and defaults that the plan depends on should be re-read with 'tailscale up --help' and 'tailscaled --help' on the pinned version before the plan is frozen.
- Kernel mode in a container needs dev0, which Proxmox reserves to root@pam. Choosing kernel mode means either a root-run host step outside OpenTofu (with provider drift to handle) or a VM.
- Userspace mode is rated less mature and slower by Tailscale's own comparison page. Long SSH sessions, the Proxmox web console (websockets, noVNC) and Ansible runs over it are untested here.
- With source NAT on, every remote session reaches the targets from one address. Target logs cannot tell clients apart; attribution exists only in Tailscale's own logs and policy.
- Carrier-grade NAT at home plus a mobile network on the client side may force all traffic through DERP relays. That works but is slower, and it makes remote administration depend on Tailscale's relay fleet as well as its control plane.
- Tailnet lock needs two signing nodes and Android cannot be one. If the owner's only second device is an Android phone, a second signing node must be found without using the subnet router.
- A lost or wiped state directory under tailnet lock locks the node out until the owner signs it from a signing node. If that happens while the owner is away, remote access is gone until someone is home; the laptop being a signing node covers the signing but not a dead container.
- Auth keys expire after at most 90 days, so the rebuild path always contains one manual step (mint a key) unless an OAuth client secret is stored, which is a long-lived credential in its own right.
- A pre-signed auth key carries a tailnet lock signing key inside it. Storing one in the private repository would weaken the lock.
- The tailscale package depends on iptables; on Debian 13 that front end and a role-managed nftables table share the kernel ruleset. A role that reloads nftables with 'flush ruleset' would silently remove Tailscale's rules in kernel mode.
- 1.104.1 was released yesterday. Pinning it immediately means running a one-day-old release on the only remote access path.
- 128 MiB may be exceeded during unattended upgrades, and an out-of-memory kill of tailscaled while the owner is away ends remote access until the unit restarts (Restart=on-failure is set in the packaged unit).

### Open points

- Userspace acceptance test: with tailscaled started with --tun=userspace-networking and the /32 routes approved, from the laptop on mobile data open ssh to 10.0.10.10, the Proxmox console on 8006 including a noVNC session, and run one Ansible play. On pve1 check the source address in 'journalctl -u ssh' and confirm it is the container's 10.0.30.x address.
- Whether an unprivileged Debian 13 container on PVE 9.2 really lacks /dev/net/tun without dev0, and whether keyctl is needed at all: create the container with the token, run 'ls -l /dev/net/tun' and start tailscaled in kernel mode; note the error.
- Whether net.ipv4.ip_forward can be set from inside the unprivileged container (kernel mode only): 'sysctl -w net.ipv4.ip_forward=1' in the guest.
- /32 routes: advertise the eight host routes, confirm they appear and are auto-approved for the tag in the admin console, and that 'tailscale status --json' on the laptop lists them.
- Shields-up: set 'tailscale set --shields-up' on the test node and confirm routed connections stop; unset it again. This confirms the source reading.
- Exact firewall rules tailscaled installs in kernel mode and which front end it picks on Debian 13: 'nft list ruleset' before and after 'tailscale up', with TS_DEBUG_FIREWALL_MODE unset and set to nftables.
- Own nftables table next to Tailscale's rules: load the role's table, confirm a connection to a non-listed port on a listed host is dropped and a listed one passes; then 'systemctl reload nftables' and confirm Tailscale's rules are still present.
- Egress minimum: with only DNS and TCP 443 open, confirm the node logs in and a relayed session works; then add UDP 3478 and UDP from 41641 and check 'tailscale netcheck' and 'tailscale ping <laptop>' for a direct path; finally confirm nothing breaks with TCP 80 closed.
- Memory: record 'systemctl status tailscaled' (Memory and peak) and 'pct exec <id> -- free -m' idle, during an SSH plus web console session, and during an unattended-upgrades run, for a week.
- Rebuild behaviour: destroy and recreate the container with a new one-off tagged key; confirm it appears as a new, locked-out machine, sign it, confirm routes are auto-approved, and note what happens to the old machine entry and its name.
- Restore behaviour: restore the container from Proxmox Backup Server and confirm it comes back with the same node key, no signature step and working routes.
- Whether --stateful-filtering=true can be enabled with source NAT on without breaking the routed sessions (kernel mode only).
- Whether unattended-upgrades touches the Tailscale repository with Debian 13 defaults: 'unattended-upgrade --dry-run -d' after a newer tailscale version is published, with the apt pin in place.
- Whether the TerraformProvisioner role can create a container and attach it to VLAN 30 once SDN.Use for that VLAN is added: 'tofu plan' and apply of a throwaway container.
- WSL2 with default NAT networking: confirm that ssh and Ansible started inside WSL reach 10.0.10.10 through the Windows Tailscale client, and check for stalls caused by the smaller tunnel MTU (not researched here).

### Findings

**1 (requirements on Debian 13)** (`primary`)

Kernel mode (the default on Linux when tailscaled runs as root) needs: access to /dev/net/tun; IP forwarding (Tailscale's documented steps write net.ipv4.ip_forward = 1 and net.ipv6.conf.all.forwarding = 1 to /etc/sysctl.d/99-tailscale.conf and run sysctl -p on it); and a netfilter front end, because the Debian package declares 'Depends: iptables' (Recommends: tailscale-archive-keyring, iproute2). tailscaled then writes its own firewall rules (netfilter mode 'on' is the default). The firewall-mode page says tailscaled uses iptables unless TS_DEBUG_FIREWALL_MODE (auto|iptables|nftables) is set in /etc/default/tailscaled. No IPv6 at this site, so the IPv6 sysctl is optional. The UDP GRO tuning (ethtool -K <dev> rx-udp-gro-forwarding on rx-gro-list off, kernel 6.2+) is a throughput optimisation only and is not needed for one admin. Userspace mode needs none of this (see question 2).

Source: https://tailscale.com/kb/1019/subnets ; https://pkgs.tailscale.com/stable/debian/dists/trixie/main/binary-amd64/Packages ; https://tailscale.com/docs/features/firewall-mode.md ; https://tailscale.com/kb/1320/performance-best-practices

**1 (blocker for the LXC form: TUN passthrough needs root@pam)** (`primary`)

Tailscale's LXC page says unprivileged Proxmox containers have no /dev/net/tun by default and gives 'pct set CTID --dev0 /dev/net/tun' and 'pct set CTID --features keyctl=1,nesting=1' (it does not say keyctl/nesting are required). Proxmox's own permission check (check_ct_modify_config_perm in pve-container LXC.pm) rejects both for anyone but root@pam: 'configuring device passthrough is only allowed for root@pam' and 'changing feature flags (except nesting) is only allowed for root@pam'. So the token terraform@pve!tofu cannot give a container a TUN device, whatever privileges its role holds. Kernel-mode Tailscale in an LXC therefore needs a root step on the host (for example pct set run locally by the pve Ansible play, which already uses become) outside OpenTofu, or a VM instead of a container, or userspace mode, which needs no TUN at all.

Source: https://tailscale.com/docs/features/containers/lxc/lxc-unprivileged.md ; https://raw.githubusercontent.com/proxmox/pve-container/master/src/PVE/LXC.pm ; infrastructure\ansible\playbooks\group_vars\proxmox.yaml:44

**1 (current version, install, pin)** (`primary`)

Current stable is 1.104.1, released 2026-10-07 (one day old today); before it 1.102.5 (2026-10-05), 1.102.4 (2026-09-10). Debian has no 'tailscale' source package (tracker.debian.org/pkg/tailscale returns 404), so the vendor repository is the only apt source. Vendor steps for trixie: key from https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg into /usr/share/keyrings/tailscale-archive-keyring.gpg; source line 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main' in /etc/apt/sources.list.d/tailscale.list. The repository index keeps old versions (about 149 versions of the package are listed, newest entries 1.104.1, 1.102.5, 1.102.4, 1.102.3, 1.102.2; version strings are plain, e.g. '1.104.1'), so an exact pin works: apt-get install tailscale=<version> plus an apt preferences pin or apt-mark hold. Also turn off the client's own updater (tailscale set --auto-update=false, or autoUpdate in the config file). Package size 40.5 MB download, Installed-Size 75966 (KiB, about 74 MiB on disk). Not verified: that unattended-upgrades leaves this repository alone by default (its default origins are Debian only, from memory); check the Origins-Pattern in the lab.

Source: https://pkgs.tailscale.com/stable/ ; https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list ; https://pkgs.tailscale.com/stable/debian/dists/trixie/main/binary-amd64/Packages ; https://tailscale.com/changelog ; https://tracker.debian.org/pkg/tailscale

**1 (declarative configuration)** (`primary`)

tailscaled has a configuration file (tailscaled --config=/path, version must be "alpha0") with fields authKey (supports file: prefix), hostname, advertiseRoutes, disableSNAT, runSSHServer, shieldsUp, netfilterMode, noStatefulFiltering, acceptDNS, acceptRoutes, autoUpdate, locked (default true, blocks 'tailscale set'). The page labels it alpha: 'the schema might change in future releases'. The stable alternative is 'tailscale up' with every non-default flag given each time ('Flags are not persisted between runs; you must specify all flags each time') or 'tailscale set' per setting; --auth-key accepts 'file:<path>'.

Source: https://tailscale.com/docs/reference/tailscaled/tailscaled-config-file.md ; https://tailscale.com/docs/reference/tailscale-cli/up.md

**2 (userspace networking as a subnet router)** (`primary`)

Yes, it works for connections from tailnet clients to advertised routes. Tailscale documents 'netstack' subnet routing as the mode used on all non-Linux systems and for non-root tailscaled on Linux (--tun=userspace-networking). Documented limits: it routes at layer 4, not layer 3: 'Tailscale terminates TCP and UDP connections from the origin Tailscale peer and makes new outbound connections to the target'; only TCP and UDP; ICMP 'only ping (reconstructed)' (the source shows tailscaled runs the host's ping command); no SCTP/GRE or other IP protocols; TCP and UDP are not end to end; performance 'acceptable' against 'best' for kernel mode, recommended for 'smaller numbers of users or low bandwidth'; the hardening page adds 'poorer performance in CPU usage, latency, and throughput'; the comparison table labels its maturity 'new (in Tailscale)' against 'stable'. Source address: the source code dials the target with an ordinary socket from the host, so the target sees the guest's own LAN address chosen by the kernel routing table; --snat-subnet-routes has no meaning in this mode (inferred from the code, not stated in the docs). Processes on the node itself reach the tailnet only through the SOCKS5/HTTP proxy, which this design does not need. Every Phase R target is TCP (22, 8006, 6443, 50000, 443), so the protocol limits do not bite.

Source: https://tailscale.com/kb/1177/kernel-vs-userspace-routers ; https://tailscale.com/kb/1112/userspace-networking ; https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/netstack/netstack.go ; https://tailscale.com/docs/reference/best-practices/device-hardening.md

**3 (source address seen by the target)** (`primary`)

Default (SNAT on): 'By default, a device behind a subnet router sees traffic as originating from the subnet router'; the docs call it masquerading. In practice sshd on 10.0.10.10 sees the subnet router's own address on its LAN interface, i.e. the container's fixed address in 10.0.30.0/24, and the router's fw4 sees the same source when the packet crosses from the remote zone to mgmt. With --snat-subnet-routes=false (Linux kernel mode only): 'the end device sees the IP address of the originating device as the source, which might be a Tailscale IP address' (100.x). The LAN side then needs a return route: network 100.64.0.0/10, next hop the subnet router's LAN address (here: a static route on the OpenWrt router plus fw4 rules that name 100.x sources); the site-to-site guide additionally asks for MSS clamping on tailscale0 and, on new routers, --stateful-filtering=false. For rules that should name one fixed address in 10.0.30.0/24, the default (SNAT on) is the right setting; it needs no route for 100.64.0.0/10 anywhere at home and it satisfies 'never source-NATed into VLAN 10 or to the workstation address', because the translated address is the remote VLAN's own. Cost: targets log the subnet router's address, not the client; per-client control stays in the Tailscale policy. The exact rule tailscaled installs (chain name, mark, MASQUERADE) was not read today: not verified, read it with 'nft list ruleset' in the lab.

Source: https://tailscale.com/kb/1214/site-to-site ; https://tailscale.com/docs/features/subnet-routers.md ; https://tailscale.com/kb/1080/cli

**4 (host routes, limits, approval)** (`secondary`)

--advertise-routes takes a comma-separated list of CIDR prefixes. I found no Tailscale page that shows a /32 example or states a maximum number of routes; a Tailscale forum answer only says there is no limit beyond what the kernel supports. Indirect primary support: the policy reference says of autoApprovers that it 'also permits the auto approvers to advertise a subnet of the specified routes', and the subnet page says overlapping routes with different prefix lengths are supported. Treat '/32 host routes work' as likely but to be confirmed in the lab (eight /32 routes here). Approval: an advertised route does nothing until approved, either in the admin console or automatically: 'the auto approver of a route or exit node can be a user's full login email address, a group name, an autogroup or a tag', example "autoApprovers": {"routes": {"192.0.2.0/24": ["tag:foo"]}}. So one entry per covering prefix (10.0.10.0/24, 10.0.50.0/24, or each /32) with the router's tag approves the routes of any node carrying that tag, including a rebuilt one. Access is separate from approval: grants are deny-by-default and can name the route as dst with ports in the ip field (for example "tcp:22"), so the tailnet policy can repeat the target list exactly.

Source: https://tailscale.com/docs/reference/syntax/policy-file.md ; https://tailscale.com/kb/1019/subnets ; https://tailscale.com/docs/features/access-control/grants.md ; https://forum.tailscale.com/t/theoretical-limit-to-advertised-routes/773

**5 (outbound connections)** (`primary`)

Tailscale needs no inbound rule. Documented outbound set: TCP to *:443 (coordination server, other backend systems, and DERP relay data, all HTTPS); TCP to *:80 ('Connections to the coordination server prefer to use HTTP on port 80 with an efficient encrypted transport'; also captive-portal detection against relay servers); UDP from source port 41641 to *:* (direct WireGuard); UDP to *:3478 (STUN). Hostnames: login.tailscale.com, controlplane.tailscale.com, log.tailscale.com, console.tailscale.com, and DERP as derpN-all.tailscale.com, N = 1..28 as of August 2025. Fixed ranges exist only for the control plane: login and controlplane in 192.200.0.0/24, log in 199.165.136.0/24. DERP addresses are not fixed; the live list is https://login.tailscale.com/derpmap/default (28 regions today; default DERP port 443, STUN port 3478 per tailcfg). The node also needs DNS, and apt needs pkgs.tailscale.com:443 and the Debian mirrors. With only TCP 443 (plus DNS) allowed: it still works; all traffic goes through DERP relays: 'you'll still be able to send and receive traffic, thanks to our secure relays (DERP), but the relayed connection won't be as fast as a peer-to-peer one'.

Source: https://tailscale.com/kb/1082/firewall-ports ; https://login.tailscale.com/derpmap/default ; https://raw.githubusercontent.com/tailscale/tailscale/main/tailcfg/derpmap.go

**5 (minimum egress rule set and cost of each removal)** (`primary`)

Rule set for the remote zone towards wan only: (a) DNS to the resolver; (b) TCP 443 to any: mandatory, removal breaks login, policy updates and relays; it cannot be narrowed to addresses for DERP because relay IPs change, only the control plane has fixed ranges; (c) UDP 3478 to any: removal means the node cannot learn its public mapping, so no direct paths, relay only; (d) UDP from 41641 to any: removal means relay only; (e) TCP 80 to any: the documented cost of removal is only that the control connection uses 443 instead and captive-portal detection is lost (irrelevant at home); the docs do not state any further cost, so 'safe to omit' is likely, not proven. Smallest working set: (a)+(b), relay-only, slower but enough for SSH and a web console. Recommended: (a)+(b)+(c)+(d). Whether direct paths ever form from behind this ISP's carrier-grade NAT to a phone network is not predictable from documentation; measure with 'tailscale ping' and 'tailscale netcheck'.

Source: https://tailscale.com/kb/1082/firewall-ports

**6 (memory and disk)** (`not-verified`)

Disk: the package is about 74 MiB installed (Installed-Size 75966) plus a small state file; verified in the repository index. Memory: Tailscale publishes no figure for tailscaled's resident memory; not verified. What exists: an OpenWrt forum thread where htop showed about 90 MB for tailscaled while the percentage display was inflated by Go's virtual address reservation; an open Tailscale issue (7272) about out-of-memory kills on a 128 MB OpenWrt device under heavy traffic; and Tailscale's September 2026 blog saying 1.104 reduces buffer memory on Linux. My assessment, not a sourced fact: 128 MiB for Debian 13 + systemd + journald + sshd + tailscaled is plausible when idle but leaves little margin, and the peaks come from apt and unattended-upgrades (Python), not from tailscaled. A Proxmox container memory value is a ceiling, not a reservation (from memory, not verified today), so setting 256 MiB with some swap costs the host nothing unless used. Start at 256 MiB, record peak usage over a week including an unattended-upgrades run, then lower it if the numbers allow. Either value fits the 1.8 GiB headroom.

Source: https://pkgs.tailscale.com/stable/debian/dists/trixie/main/binary-amd64/Packages ; https://forum.openwrt.org/t/tailscale-using-130-of-memory/233649 ; https://github.com/tailscale/tailscale/issues/7272 ; https://tailscale.com/blog/making-tailscale-faster

**7 (identity, rebuild, signing)** (`primary`)

The packaged unit runs 'tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${PORT} $FLAGS' with StateDirectory=tailscale mode 0700 and EnvironmentFile=/etc/default/tailscaled. That state file holds the node's keys, including its tailnet lock key ('each of your nodes stores tailnet-lock keys and other important data that should be preserved'). If /var/lib/tailscale survives (a restored container backup), the node keeps its identity, signature and approved routes. A guest rebuilt from scratch with a new auth key is a new node with a new node key: under tailnet lock it shows 'Locked out' and cannot talk to peers until a signing node runs 'tailscale lock sign nodekey:<key> tlpub:<key>'. Routes need no manual step if autoApprovers names the tag, and grants written against the tag keep applying. Alternative: a pre-signed auth key ('tailscale lock sign <auth-key>') joins without a later signature, but each such key creates a new trusted signing key whose private half is inside the key string, so storing one in Git, even encrypted, stores signing power. Auth keys live 1 to 90 days, so a key kept in SOPS will usually be stale at rebuild time: minting a fresh one-off tagged key is a manual rebuild step (an OAuth client can mint keys, but adds a long-lived credential). Key expiry: a node authenticated with a tag has key expiry disabled by default; user devices default to 180 days (range 1 to 180). Renewal of an already signed node needs no new signature ('the new node key will not need to be re-signed'), but logging in afresh instead of re-authenticating destroys the lock key and locks the node out.

Source: https://raw.githubusercontent.com/tailscale/tailscale/main/cmd/tailscaled/tailscaled.service ; https://tailscale.com/kb/1226/tailnet-lock ; https://tailscale.com/docs/reference/tailscale-cli/lock.md ; https://tailscale.com/docs/reference/reauth-under-tailnet-lock.md ; https://tailscale.com/kb/1085/auth-keys ; https://tailscale.com/docs/features/access-control/key-expiry.md

**7 (tailnet lock preconditions that affect this node)** (`primary`)

Tailnet lock is on the Personal (free) plan ('available for the Personal and Enterprise plans'). It cannot be combined with device approval ('mutually exclusive features'), which confirms the correction already given to the owner. Enabling it needs 'tailscale lock init' with at least two signing nodes; an Android device cannot be a signing node; maximum 20 signing nodes; clients must be 1.46.1 or later; ten disablement secrets are produced by the documented flow and one is enough to disable the lock. The subnet router should not be a signing node: its job is to be exposed, and a signing key on it would let whoever takes it over add nodes.

Source: https://tailscale.com/kb/1226/tailnet-lock ; https://tailscale.com/docs/features/tailnet-lock.md

**8 (hardening options and whether they combine with subnet routing)** (`primary`)

Does NOT combine: --shields-up. The source builds a filter with no allow rules when shields-up is set (NewShieldsUpFilter: 'returns a packet filter that rejects incoming connections'), and advertised routes pass through that same filter, so routed traffic is dropped as well. I read this in the source through a summarising fetch, not in a doc page: confirm with a one-minute lab test. Combines: (1) Tailscale SSH is off unless --ssh is given ('Defaults to false'); leave it off and keep the ssh section out of the policy. (2) Blocking access to the node itself while it routes is done in the tailnet policy: grants name only the route addresses and ports as destinations and never the router's tag, so its own 100.x address accepts nothing. (3) Own nftables rules combine with Tailscale's: in netfilter mode 'on' tailscaled accepts traffic from tailscale0 early, but in nftables an accept in one base chain does not end evaluation ('the packet will subsequently traverse this other chain'), while 'drops take immediate effect'. A separate table with forward policy drop that allows only tailscale0 to the eight target address and port pairs, and an input chain that drops everything from tailscale0, is therefore effective next to Tailscale's rules. Mode 'nodivert' or 'off' is only needed if you want to own the NAT and accept rules yourself; it adds work and no protection here. Caution, from memory and not verified today: Debian's stock /etc/nftables.conf begins with 'flush ruleset', which would also delete Tailscale's rules on reload; the role should manage its own table only. (4) --stateful-filtering is off by default (it was on in 1.66.0 and switched off in 1.66.4); with SNAT on it can be enabled as an extra guard, to be tested. (5) Reduced privileges in kernel mode: Tailscale documents a systemd setup with User=tailscaled and only CAP_NET_ADMIN and CAP_NET_RAW (CAP_SYS_MODULE can be dropped when the TUN module is already present), plus NoNewPrivileges, ProtectSystem, SystemCallFilter. This is a drop-in on top of the packaged unit, which runs as root. (6) Userspace mode needs no capabilities, no TUN and no forwarding; the allow-list then goes in an nftables output chain, which can match the tailscaled user, and kernel forwarding stays off entirely.

Source: https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/filter/filter.go ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnlocal/local.go ; https://tailscale.com/docs/reference/netfilter-modes.md ; https://wiki.nftables.org/wiki-nftables/index.php/Configuring_chains ; https://tailscale.com/docs/reference/best-practices/device-hardening.md ; https://tailscale.com/docs/reference/tailscale-cli/up.md

**Repository context** (`repository`)

The approved design text is in ARCHITECTURE.md line 389 (VLAN 30, own fw4 zone and E-rows, no source NAT into VLAN 10, 128 MiB LXC preferred, device approval listed next to tailnet lock, which must now be dropped). The router's WAN address is in 172.16.131.128/26, so there is no overlap with Tailscale's 100.64.0.0/10. The TerraformProvisioner role grants SDN.Use per VLAN path under /sdn/zones/localnetwork/vmbr0/<vlan>; VLAN 30 is not among the guest VLANs yet, so the token cannot attach a guest to it until that list is extended. The role has no container-specific gap that I checked beyond the root@pam-only settings above; whether its privilege list is enough to create a container at all was not checked against the Proxmox API.

Source: docs\ARCHITECTURE.md:389 ; infrastructure\ansible\playbooks\group_vars\proxmox.yaml:44-96

## Identity, policy and management as code

### Recommendation

Tailscale's free Personal plan covers everything Phase R needs. Three corrections to the approved design follow from the sources.

1. Drop device approval. It cannot be on together with tailnet lock; set devices_approval_on = false explicitly and correct docs/ARCHITECTURE.md line 389.
2. Do not use pre-signed auth keys. Tailscale advises against them because the signed key carries a signing key that stays trusted after use.
3. Two-factor login at GitHub cannot be enforced or checked by Tailscale. It becomes a documented manual step with a periodic check.

Recommended shape for the plan:

- Identity: one Owner, the personal GitHub account, with a hardware key or authenticator app and stored recovery codes. Record in an ADR that a GitHub tailnet cannot be migrated to another identity provider later.
- Policy as code: a new OpenTofu root beside "pve" (for example infrastructure/opentofu/roots/tailscale) with provider tailscale/tailscale pinned to 0.29.2. It holds one tailscale_acl resource reading a HuJSON file from Git, and one tailscale_tailnet_settings resource (key expiry length, device approval off, user approval on, console edits blocked). It is run from the workstation through the existing sops exec-env wrapper.
- Credential: one OAuth client with scopes policy_file and feature_settings only, created by hand once, secret in SOPS. Avoid an API access token: it has full owner rights and must be renewed at least every 90 days.
- CI: offline checks only (tofu fmt, tofu validate, HuJSON parse). The policy tests run at plan time on the workstation. Do not use the GitHub Action to apply policy.
- Policy content: grants only, no acls and no ssh section. Source is a host alias for the laptop's tailnet address; destinations are host routes for the administration targets with explicit TCP ports, via the router's tag. tagOwners is "[]", autoApprovers lists the same host routes for the tag, and tests assert both the allowed ports and the denials (phone, router as source, router as destination). Replace the default allow-all policy before the router is enrolled.
- Tagged router: enrol by interactive login with --advertise-tags, then sign it from the laptop. No auth key, no OAuth client, nothing in state. Leave its key expiry disabled (the default for tagged nodes) and record that as a documented exception.
- Tailnet lock: signing nodes are the laptop and one more. Use the phone if it is an iPhone, otherwise the subnet router. Enable the lock only after both exist. Generate two or three disablement secrets, store them in Bitwarden and on paper, none in Git and none with Tailscale support.
- Key expiry: set the length before enrolling devices. 180 days is the default; 90 is a reasonable tighter value, since renewing only needs internet and the GitHub login.
- Runbooks: tailnet bootstrap, lock enablement, router rebuild and re-signing, laptop key renewal while away, and lost laptop. The lost-laptop order is: remove device, revoke GitHub sessions, remove the laptop's lock key from the second signer, revoke the OAuth client, rotate the other workstation secrets, then collect the proof listed in the findings.

Keep the fw4 rules for VLAN 30 as the narrowest and final layer. They are the one control that neither a GitHub takeover nor Tailscale can change.

### Risks

- The GitHub account is the single root of trust for the tailnet. Tailscale cannot verify its second factor, and a stolen laptop may carry a logged-in GitHub browser session.
- Tailnet lock does not protect the policy file. An attacker in the admin console can still change rules among already-signed devices, remove devices and change DNS settings. Only the home router's VLAN 30 rules bound that.
- The laptop is both the admin device and a signing node. Until its lock key is removed from another signing node, a thief holds a trusted signing key, and that removal is CLI-only so it cannot be done from a phone browser.
- With only two signing nodes, losing both, or losing the laptop when the second signer is unreachable, leaves the disablement secret as the only way out. Losing the secrets as well means building a new tailnet.
- The tagged router's node key never expires by default. Anyone who copies the container's Tailscale state directory, or a backup of it, has a standing identity inside the tailnet.
- The OAuth client secret for OpenTofu does not expire and can rewrite the access policy. It lives in SOPS on the same laptop that may be lost.
- The free plan has no network flow logs. After an incident Tailscale can show configuration changes but not traffic, so traffic evidence depends on logging at home.
- The provider is version 0.x; resource behaviour may change between minor versions. tailscale_acl overwrites the whole policy file, so a wrong apply can cut off remote access or open it up.
- A GitHub-backed tailnet cannot be migrated to another identity provider; changing later means re-enrolling every device and redoing the lock.
- The Personal plan is for non-commercial use, and its limits and features are set by the vendor and can change; the 2026 pricing page should be re-read before each phase that depends on it.
- If 'prevent edits in the admin console' is on, an emergency policy change from a phone needs that setting switched off first, which costs time during an incident.

### Open points

- Is the 'via' field accepted on the Personal plan, and does a via grant alone make the router usable, or does the laptop also need a grant to the router itself? Verify: submit the example policy to POST /tailnet/{tailnet}/acl/validate (or run tofu plan), then from the laptop on mobile data test tcp 22 and 8006 to 10.0.10.10 and confirm that ping and SSH to the router's 100.x address fail.
- Do policy tests take 'via' and a host-alias source into account, and does a test with the user as source evaluate as expected when the grant's source is an IP alias? Verify: run the example tests through acl/validate, then deliberately break one grant and confirm the plan fails.
- Can a tagged node be a tailnet-lock signing node? Verify: read its tlpub with 'tailscale lock status' on the container and try to select it in the enable wizard. Before that, ask the owner whether the phone is an iPhone (can sign) or Android (cannot).
- What happens to a removed node under tailnet lock: can a removed signing laptop log in again and become usable without a new signature? Verify in a rehearsal: remove a test device, log it in again, and check for the 'Locked out' badge and 'tailscale lock status' before and after removing its tlpub.
- Does the provider work under OpenTofu 1.13 with state and plan encryption enforced, and does the plan really fail on a failing policy test? Verify: tofu init and plan in the new root with a deliberately failing test.
- Exact scopes for the OAuth client: confirm that policy_file plus feature_settings is enough for tailscale_acl and tailscale_tailnet_settings (the schema says so for the endpoints; the provider was not run). Verify: create the client with only those scopes and run plan and apply.
- Is workload identity federation available on the Personal plan? Only matters for the optional read-only pull-request check. Verify: look for 'federated identity' under Trust credentials in the admin console.
- Does Tailscale warn before a key expires, by e-mail or in the client? Verify: read the client and admin console once devices are enrolled; until known, the runbook should say to check the expiry date before travel.
- Which GitHub permissions Tailscale requests at sign-in, and how the tailnet is named for a personal account. Verify: read the GitHub authorisation screen during bootstrap and record it in the runbook.
- How to check the GitHub account's second factor without the browser: the 'two_factor_authentication' field of GitHub's GET /user response was not verified today. Verify with 'gh api user' on the workstation.
- Whether fw4 and target logs should distinguish tailnet devices: by default the subnet router source-NATs to its own VLAN 30 address. Turning that off ('--snat-subnet-routes=false', Linux only) needs a return route for 100.64.0.0/10 and belongs to the network-design question; decide there.
- Whether the container's Tailscale state should be included in or excluded from the backup server's backups (restore without re-enrolment versus a node key in backups). Owner decision; either way document it in the secrets register.
- Quoted sentences came through an extraction model. Before any quote is copied into repository documentation, re-read the page.

### Findings

**0. Method note (applies to every finding)** (`primary`)

All web pages were read today (2026-10-08) through a fetch tool that passes the page through an extraction model. Quoted sentences are as that tool returned them; copy them into repo docs only after re-reading the page. Two sources were read as raw text and are exact: the Tailscale OpenAPI schema (grepped locally) and the registry/GitHub API JSON. Nothing was tested against a real tailnet: no tailnet exists yet, so the example policy is checked against documentation only, not machine-validated.

Source: https://api.tailscale.com/api/v2?outputOpenapiSchema=true

**1. Free Personal plan: what it includes** (`primary`)

Pricing page: Personal is $0 'Free forever'; 'Up to 6 users'; 'Unlimited user devices'; 'Up to 50 tagged resources to start' (table: '50 tagged resources included; add more for $1/month each'; a tagged resource is 'a device that is owned by a tag rather than a user identity'); '1,000 mins per month for ephemeral resources'; 'Up to 3 ACL groups'; 'Subnet routers & exit nodes' included; 'ACLs (Zero Trust)' included; device approval and user approval included; 'Basic Tailscale SSH' up to 5 hosts; 'Basic device posture (OS and TS version)'; configuration audit logs and webhooks included; network flow logs and log streaming NOT included. The plan is 'only suitable for non-commercial use'. Feature docs: 'Subnet routers are available for all plans'; 'Device approval is available for all plans'; 'Tailnet Lock is available for the Personal and Enterprise plans' (the pricing table itself had no tailnet-lock row); key expiry customisation 'available for all plans' (1 to 180 days); 'Configuration audit logs are available for all plans', kept for 'the most recent 90 days', not adjustable; 'The Tailscale API is available for all plans'. Tags doc: 'All plans include 50 tagged devices'. This tailnet needs 1 user, 2 user devices, 1 tagged device: far inside every limit. The repo's own research of 2026-10-05 recorded the same pricing figures.

Source: https://tailscale.com/pricing ; https://tailscale.com/docs/features/tailnet-lock ; https://tailscale.com/docs/features/access-control/key-expiry ; https://tailscale.com/docs/features/logging/audit-logging ; https://tailscale.com/docs/features/tags ; docs\research\2026-10-05-platform-research.md:106

**1. Plan limits not confirmed** (`not-verified`)

Not verified on a primary page: (a) whether grants with the 'via' field are available on Personal (the via page and the grants syntax page carry no plan note); (b) whether workload identity federation (federated identities) is available on Personal (no plan sentence on its page); (c) custom device-posture attributes: a search summary of Tailscale docs says they need Premium or Enterprise, but the attribute table on the docs page failed to render ('Missing snippet'), so this is secondary only. The design should not depend on any of the three.

Source: https://tailscale.com/docs/features/access-control/grants/grants-via ; https://tailscale.com/docs/features/workload-identity-federation ; https://tailscale.com/docs/features/device-posture/postures-and-attributes

**2. GitHub sign-in: mapping and two-factor** (`primary`)

A tailnet can be created from 'a GitHub organization account or a GitHub personal account'; other people can only enter a personal tailnet by invitation. In the policy file a GitHub user is written 'username@github'. Tailscale cannot require or check two-factor login at GitHub: 'Tailscale does not handle authentication itself. Instead, you can enable MFA features in your single sign-on identity provider'. GitHub itself forces 2FA only on accounts it selects as contributors ('Your account is selected for mandatory 2FA if you have taken some action on GitHub that shows you are a contributor'), not on every personal account. So 'GitHub identity with two-factor login' is a documented manual step with a periodic manual check; it cannot be enforced as code from the Tailscale side. Lock-in to note: 'Currently, we cannot migrate your tailnet from/to GitHub as an identity provider', so a later move to Authentik or another provider means a new tailnet. The exact GitHub OAuth scopes Tailscale requests and the tailnet's displayed name for a personal account were not verified.

Source: https://tailscale.com/docs/integrations/identity/github ; https://tailscale.com/docs/integrations/identity ; https://tailscale.com/docs/reference/syntax/policy-file ; https://docs.github.com/en/authentication/securing-your-account-with-two-factor-authentication-2fa/about-mandatory-two-factor-authentication

**2. What a GitHub account takeover gives, with and without tailnet lock** (`primary`)

This is my reasoning from the documented mechanisms, not a statement Tailscale makes. The GitHub account is the tailnet Owner. WITHOUT tailnet lock (and device approval is worthless here, because the attacker is the approver): the attacker signs in to the admin console, enrols their own device, rewrites the policy file, creates auth keys and API tokens, and reaches whatever the subnet router advertises and the home router's VLAN 30 rules allow. They cannot widen the routes from the console, because a route must be 'advertised from the device itself AND enabled'. They then stand where the design says: at pve1 tcp 22/8006 and the router and AP SSH ports, still facing SSH keys and the Proxmox login. WITH tailnet lock: a new node 'requires a signature from a Tailnet Lock key' held on a signing device, and turning the lock off needs a disablement secret, so the attacker's device stays locked out. What remains: changing policy among the already-signed devices (for example letting the phone reach the targets), removing devices (denial of service), changing tailnet DNS settings, reading the configuration log. Tailnet lock explicitly 'does not prevent a compromised control plane from breaking connectivity'. The control that neither GitHub nor Tailscale can change is the fw4 rule set for VLAN 30 on the home router; it must stay the narrowest layer.

Source: https://tailscale.com/docs/features/tailnet-lock ; https://tailscale.com/docs/concepts/tailnet-lock-whitepaper ; https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/resources/device_subnet_routes.md

**3. Tailnet lock: what it protects against** (`primary`)

'Without Tailnet Lock, when a new node joins the tailnet, the Tailscale coordination server distributes the public node key to peer nodes. If Tailscale were malicious, and stealthily inserted new nodes into your network, then Tailscale could send or receive traffic to your existing nodes in plaintext.' With it, 'its public node key requires a signature from a Tailnet Lock key'. Whitepaper: 'Tailscale infrastructure cannot add an unauthorized node to a tailnet with Tailnet Lock enabled'. Not covered: denial of service by the control plane; a malicious initial state at enablement (trust on first use); a compromised signing device ('Tailnet Lock keys are stored on the device. If the device is compromised, the key can be obtained'). Policy distribution stays with the control plane, so the lock does not protect the policy file.

Source: https://tailscale.com/docs/features/tailnet-lock ; https://tailscale.com/docs/concepts/tailnet-lock-whitepaper

**3. Tailnet lock: signing nodes for laptop + phone + tagged subnet router; can a phone sign** (`primary`)

The admin-console wizard says 'You must select at least two signing nodes' (the CLI itself only requires the key of the node running init). Maximum 20. Signing by CLI is 'possible only for Linux, macOS, and Windows'; by client signing link 'only for macOS, Windows, and iOS'; 'Using a QR code to add a node is currently supported only on iOS devices'; 'You cannot use an Android device as a signing node'. So: the Windows laptop is signing node 1. Signing node 2 is the subnet router (Linux) or the phone if it is an iPhone; an Android phone cannot be one. Two are needed in practice anyway: if the laptop is the only signer and is lost, nothing can be signed or un-trusted and the only way out is a disablement secret. Whether a tagged node may be a signing node is not stated in the docs (not verified; nothing forbids it). Consequence for ordering: the lock can only be enabled after the second signing device exists. At enablement 'All existing nodes in the tailnet are signed by the trusted Tailnet Lock keys'.

Source: https://tailscale.com/docs/features/tailnet-lock ; https://tailscale.com/docs/reference/tailscale-cli/lock

**3. Tailnet lock: commands to sign a new or rebuilt node, and pre-signed auth keys** (`primary`)

Enable: 'tailscale lock init [flags] <tlpub:trusted-key1 tlpub:trusted-key2 ...>' with '--gen-disablements <N>' (default one, the minimum), '--gen-disablement-for-support', '--confirm'. New or rebuilt node: it joins and shows as 'Locked out'; 'tailscale lock status' on it prints the command to run; on a signing node run 'tailscale lock sign nodekey:<key> tlpub:<rotation key>'. A rebuilt node has a new node key and a new lock key, so it must be signed again, and if it was a signing node its old key must be removed and the new one added ('tailscale lock remove tlpub:<old>', 'tailscale lock add tlpub:<new>'). Key expiry does not need a new signature: 'When a signed node key expires, the new node key will not need to be re-signed... the node's signature will be automatically rotated'. Pre-signed auth keys exist ('tailscale lock sign $AUTH_KEY') but Tailscale advises against them: 'a new trusted signing key gets created for it... The private key of the signing key gets encoded in the signed auth key. A signed auth key is equivalent to a private signing key on a signing node in your tailnet... Even if the auth key is single-use, the signing key remains trusted until it's removed from the tailnet key authority. For security best practices, we do not recommend using signed auth keys.' The source code confirms the auth-key path (prefix 'tskey-auth-', a separate lock key wrapped into the output). For a node rebuilt rarely: join, then sign by hand from the laptop.

Source: https://tailscale.com/docs/reference/tailscale-cli/lock ; https://tailscale.com/docs/features/tailnet-lock ; https://raw.githubusercontent.com/tailscale/tailscale/main/cmd/tailscale/cli/tailnet-lock.go

**3. Tailnet lock: disablement secrets, device approval, API or provider** (`primary`)

Disablement secrets: shown only at init ('You get your disablement secrets only when you initialize Tailnet Lock'); one is enough to disable ('tailscale lock disable <disablement-secret>'); once used it 'should be considered public'; 'If you lose your disablement secrets, and you did not provide one to Tailscale support, the tailnet cannot be recovered'. Storage advice from the docs: 'a password manager, or printing them and storing them in a secure safe'. For this lab: generate two or three, keep them in Bitwarden beside the offline age key plus one printed copy; not in Git; and do not hand one to Tailscale support, since the point of the lock is not to trust the control plane (for a three-device tailnet the worst case of losing them is building a new tailnet). Device approval: 'You cannot enable both Tailnet Lock and device approval—they are mutually exclusive features.' This confirms the correction to ARCHITECTURE.md line 389, which lists both. Management as code: none. The OpenAPI schema has no tailnet-lock endpoint; it only exposes read-only device fields 'tailnetLockKey' and 'tailnetLockError' and audit-log event types (TAILNET.ENABLE.TKA and similar). The provider's tailnet_settings resource has no lock argument and no lock resource exists. The admin console only generates the CLI command. So enabling, signing and key removal are CLI steps in a runbook; state can be checked with 'tailscale lock status --json' and 'tailscale lock log'. Rotate lock keys 'at most once per year'.

Source: https://tailscale.com/docs/features/tailnet-lock ; https://tailscale.com/docs/reference/tailscale-cli/lock ; https://api.tailscale.com/api/v2?outputOpenapiSchema=true ; https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/resources/tailnet_settings.md ; docs\ARCHITECTURE.md:389

**4. Policy file: recommended syntax, tags, auto-approval, tests** (`primary`)

Grants are the recommended form: 'Grants can do everything ACLs can, plus they facilitate application-level permissions and route filtering'; 'Grants and legacy ACLs can coexist in the same tailnet policy file'; grants are deny-by-default. A new tailnet starts with an allow-all grant (src '*', dst '*', ip '*'), which must be replaced before the router is enrolled. Grant fields: src and dst accept users, groups, tags, autogroups, '<cidr>/<ip>', host aliases, ipsets; ip accepts '*', '<port>', '<proto>:<port>' such as 'tcp:443'; via: 'You can only use tags within the via field' and 'you can only use accessible routers as via candidates'. Docs example for a subnet: src group, dst '192.0.2.0/24', ip '*', via 'tag:subnet-router'. tagOwners: owners may be users, groups, autogroups or tags; '[]' means only autogroup:admin and autogroup:network-admin may assign the tag. autoApprovers.routes maps a CIDR to users, groups or tags and 'also permits the auto approvers to advertise a subnet of the specified routes'. tests: 'assertions about your access control policies (grants and ACLs) that run as checks each time the tailnet policy file changes'; src is 'a user's email address, a group, a tag, or a host that maps to an IP address'; accept and deny entries are 'host:port' with a single port; 'You cannot use CIDR (subnet) notation'; proto omitted means TCP or UDP; a failing test makes Tailscale reject the file. sshTests only assert Tailscale SSH rules (src, dst, accept, check, deny); they are irrelevant here because Tailscale SSH should stay off. Not documented: whether tests evaluate the via field.

Source: https://tailscale.com/docs/reference/syntax/policy-file ; https://tailscale.com/docs/reference/syntax/grants ; https://tailscale.com/docs/features/access-control/grants/grants-via ; https://tailscale.com/docs/reference/examples/grants ; https://tailscale.com/docs/reference/troubleshooting/grants

**4. 'User X on device D' and keeping the subnet router itself unreachable** (`primary`)

A grant cannot AND a user with a device; src is a union. Two ways to bind to the laptop. (A) src = a host alias for the laptop's Tailscale address (allowed: src accepts an IP or host alias). It names exactly one device; the address must be re-entered in Git if the laptop is removed and re-enrolled, which is a useful explicit gate. (B) src = '<login>@github' plus srcPosture with 'node:os IN ['windows']'; this excludes the phone but matches any Windows device of the user; Personal has only OS and client-version posture. I recommend (A). The subnet router is unreachable by default-deny as long as no grant has it as dst (not its tag, not its 100.x address, not '*', not autogroup:tagged), no 'ssh' section exists and the node is not started with --ssh; it is administered from the pve1 console (pct enter), not over the tailnet. One thing to confirm in the lab: the via limitation says only 'accessible routers' qualify and the troubleshooting page says to check the via device 'is reachable from the source device using tailscale ping'; whether a via grant alone is enough, or the laptop also needs some grant to the router, is not documented.

Source: https://tailscale.com/docs/reference/syntax/grants ; https://tailscale.com/docs/features/access-control/grants/grants-via ; https://tailscale.com/docs/reference/troubleshooting/grants ; https://tailscale.com/pricing

**4. Example policy (HuJSON), checked against the policy-file, grants and via reference pages only** (`primary`)

Placeholders in angle brackets are deliberate: the laptop's tailnet address exists only after enrolment and the router's SSH address is not assumed. Not validated by the API.

{
  // "[]": only Owner/Admin may assign the tag.
  "tagOwners": {
    "tag:lab-router": [],
  },
  "hosts": {
    "admin-laptop": "<laptop 100.x address>",
    "pve1": "10.0.10.10",
    "ap1": "10.0.10.2",
    "ap2": "10.0.10.3",
    "router-ssh": "<router SSH address>",
  },
  // Only these host routes may be advertised, and only by the tagged router.
  "autoApprovers": {
    "routes": {
      "10.0.10.10/32": ["tag:lab-router"],
      "10.0.10.2/32": ["tag:lab-router"],
      "10.0.10.3/32": ["tag:lab-router"],
      "<router SSH address>/32": ["tag:lab-router"],
    },
  },
  "grants": [
    {
      "src": ["admin-laptop"],
      "dst": ["pve1"],
      "ip": ["tcp:22", "tcp:8006"],
      "via": ["tag:lab-router"],
    },
    {
      "src": ["admin-laptop"],
      "dst": ["ap1", "ap2", "router-ssh"],
      "ip": ["tcp:22"],
      "via": ["tag:lab-router"],
    },
  ],
  "tests": [
    {
      "src": "admin-laptop",
      "proto": "tcp",
      "accept": ["pve1:22", "pve1:8006", "ap1:22", "ap2:22"],
      "deny": ["pve1:3128", "ap1:80", "10.0.10.254:22", "tag:lab-router:22"],
    },
    {
      // any other device of the owner, e.g. the phone
      "src": "<login>@github",
      "proto": "tcp",
      "deny": ["pve1:22", "pve1:8006", "tag:lab-router:22"],
    },
    {
      "src": "tag:lab-router",
      "proto": "tcp",
      "deny": ["admin-laptop:22", "admin-laptop:3389"],
    },
  ],
}

Later phases add 10.0.50.10 tcp 6443, 10.0.50.11 and .21 tcp 50000, and 10.0.50.201 tcp 443 as further hosts, routes and grants. If via turns out not to work on the free plan, drop the via lines: with one router advertising the routes the effect is the same.

Source: https://tailscale.com/docs/reference/syntax/policy-file ; https://tailscale.com/docs/reference/syntax/grants ; https://tailscale.com/docs/features/access-control/grants/grants-via

**5. Key expiry** (`primary`)

Default: 'By default, new domains are set with an expiry period of 180 days'. Tailnet-wide setting 'from 1 to 180 days' (API field devicesKeyDurationDays, minimum 1, maximum 180; provider argument devices_key_duration_days). A change 'applies to any devices that are logged in after you make the change', so set it before enrolling devices. Tagged devices: 'When you apply a tag to a device for the first time and authenticate it, the tagged device will have key expiry disabled by default'. Per device it can be switched in the admin console, by API (POST /device/{id}/key, keyExpiryDisabled) or with the provider's tailscale_device_key. When a key expires 'connections to/from the given endpoint will stop working'. Laptop away from home with an expired key: it needs only ordinary internet and the GitHub login. Run 'tailscale up --force-reauth' (or reauthenticate from the client) and sign in at GitHub with the second factor; under tailnet lock the signature rotates by itself. From any browser the Owner can also choose 'Temporarily extend key', which lasts 30 minutes. The docs warn that --force-reauth 'might bring down the tailnet connection and thus should not be done remotely over SSH or RDP'. Practical rule for the runbook: check the laptop's expiry date before travel and carry the second factor. Whether Tailscale sends a warning before expiry was not verified.

Source: https://tailscale.com/docs/features/access-control/key-expiry ; https://api.tailscale.com/api/v2?outputOpenapiSchema=true ; https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/resources/device_key.md

**6. Authenticating the tagged node: which leaves the least standing secret** (`primary`)

(a) Interactive login with a tag: 'sudo tailscale login --advertise-tags=tag:server' (or tailscale up with the same flag) prints a login URL; the Owner signs in at GitHub in a browser; the node becomes owned by the tag and, per the tags page, no user credential stays on it. No secret is created, stored or passed through Ansible. (b) Auth key: one-off or reusable, optionally tagged, pre-approved, ephemeral; expiry 1 to 90 days ('will expire after the maximum of 90 days' if unset); needs Owner, Admin, IT admin or Network admin to create; 'any device authorized by it remains authorized until its node key expires'; 'Revoking a key does not deauthorize nodes using the key'. A one-off key with one day of life exists for at most a day and dies on first use, but it has to travel from the console (or from OpenTofu state, where tailscale_tailnet_key stores the 'key' attribute as a sensitive value) into the Ansible run. (c) OAuth client: 'tailscale up --auth-key=${OAUTH_CLIENT_SECRET}' with 'ephemeral=false&preauthorized=true'; needs the auth_keys scope and tags; the secret does not expire (Tailscale's Terraform page: trust credentials 'do not expire, and support scopes') and keeps working 'even if the user no longer has access to the tailnet'. Ranking for a node rebuilt rarely: (a) no standing secret; (b) a secret for at most a day; (c) a permanent secret able to enrol tagged nodes. Under tailnet lock every path still ends with a manual 'tailscale lock sign' on the laptop, so (a) costs one extra browser click and removes the secret entirely. The standing credential in all cases is the node's own state on the LXC disk (node key and lock key); if the LXC is restored from a backup with that state, no re-login and no re-signing is needed, which also means the backup holds that key.

Source: https://tailscale.com/docs/features/tags ; https://tailscale.com/docs/features/access-control/auth-keys ; https://tailscale.com/docs/reference/trust-credentials ; https://tailscale.com/kb/1215/oauth-clients ; https://tailscale.com/docs/integrations/terraform-provider ; https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/resources/tailnet_key.md

**7. Provider: address, version, licence, OpenTofu** (`primary`)

Source address tailscale/tailscale. Latest version 0.29.2, published 2026-05-26 (Terraform registry API and GitHub releases agree; the repository had a push on 2026-10-06, so it is active). The OpenTofu registry lists 0.29.2 as its newest version, so it installs under OpenTofu with the same address. Licence MIT. Tailscale's docs: 'Tailscale maintains the Tailscale Terraform provider'; they do not mention OpenTofu, and the registry API returned tier 'community'. It is a 0.x provider, so pin it exactly and let Renovate propose updates. It was not run against OpenTofu 1.13 here.

Source: https://registry.terraform.io/v1/providers/tailscale/tailscale ; https://registry.opentofu.org/v1/providers/tailscale/tailscale/versions ; https://api.github.com/repos/tailscale/terraform-provider-tailscale/releases/latest ; https://api.github.com/repos/tailscale/terraform-provider-tailscale ; https://tailscale.com/docs/integrations/terraform-provider

**7. Provider: resources that matter, credential, state** (`primary`)

Resources (20 in total). Needed here: tailscale_acl (the whole policy file, JSON or HuJSON, comments kept; 'will completely overwrite existing policy file contents'; 'validated against the Tailscale API during planning, so syntax errors and failing tests... are surfaced before apply'; import with 'tofu import tailscale_acl.<name> acl' or set overwrite_existing_content) and tailscale_tailnet_settings (devices_key_duration_days, devices_approval_on, users_approval_on, acls_externally_managed_on, acls_external_link, devices_auto_updates_on, network_flow_logging_on, https_enabled and others). Optional: tailscale_device_key (key_expiry_disabled), tailscale_device_tags, tailscale_device_subnet_routes (if used together with autoApprovers every auto-approved route must also be listed 'to avoid configuration drift', so use one or the other; I suggest autoApprovers only), tailscale_device_authorization (pointless with the lock), tailscale_tailnet_key, dns_* resources, tailscale_contacts, tailscale_webhook. Credential: api_key (TAILSCALE_API_KEY), or oauth_client_id plus oauth_client_secret with 'scopes', or a federated identity token; 'Using a trust credential... is recommended... as trust credentials can have granular access scopes applied to them whereas API keys cannot'. API access tokens 'have the same permissions as the owning user, and can be set to expire in 1 to 90 days'. Scopes from the OpenAPI schema: policy file write 'policy_file' (also needed for acls_externally_managed_on); other tailnet settings 'feature_settings'; device delete, expire, key, tags, authorise 'devices:core' (a credential with it must carry tags); routes 'devices:routes'; auth keys 'auth_keys'; audit log 'logs:configuration:read'. Minimum for this plan: policy_file and feature_settings. State: the policy text and settings (not secret); with tailscale_tailnet_key the auth key itself ('key', sensitive, set only at creation). The repo's state is client-side encrypted with enforcement on, but the simplest answer is not to create key resources at all.

Source: https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/index.md ; https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/resources/acl.md ; https://raw.githubusercontent.com/tailscale/terraform-provider-tailscale/main/docs/resources/tailnet_settings.md ; https://api.tailscale.com/api/v2?outputOpenapiSchema=true ; infrastructure\opentofu\roots\pve\versions.tf:26

**7. GitHub Action for the policy file versus OpenTofu from the workstation** (`primary`)

The action is tailscale/gitops-acl-action@v1 with 'test' (runs the tests, changes nothing) and 'apply'. It accepts an API key (expires within 90 days), an OAuth client id and secret with the policy_file scope, or a federated identity (oauth-client-id plus audience, workflow permission 'id-token: write'). With an API key or OAuth secret a tailnet credential sits in GitHub secrets, which breaks 'no lab secret in CI'. With a federated identity no secret is stored, but the repository's workflow becomes a writer of the access policy, which is deployment from CI and contradicts the repo's rule that CI only validates. OpenTofu from the workstation fits the existing pattern (credentials through 'sops exec-env', encrypted state) and already runs the policy tests at plan time. A possible later refinement, if federated identities are available on Personal (not verified): a read-only identity with only 'policy_file:read', which is the scope the validate endpoint needs (POST /tailnet/{tailnet}/acl/validate 'does not modify the tailnet policy file in any way'), so pull requests could run the tests with no stored secret and no write power.

Source: https://tailscale.com/docs/integrations/github/gitops ; https://raw.githubusercontent.com/tailscale/gitops-acl-action/main/README.md ; https://tailscale.com/docs/features/workload-identity-federation ; https://api.tailscale.com/api/v2?outputOpenapiSchema=true

**7. What cannot be managed as code (documented manual steps)** (`primary`)

1. Creating the tailnet by signing in with GitHub, and GitHub's two-factor setup. 2. Everything about tailnet lock: init, storing disablement secrets, signing nodes, adding and removing signing keys (CLI only; no API, no provider resource). 3. Creating the first OAuth client for OpenTofu in the admin console (bootstrap; scopes policy_file and feature_settings) and placing its secret in SOPS. 4. Enrolling the laptop and the phone (interactive login), and the browser login for the tagged router if the no-secret path is used. 5. Removing a device: possible by API (DELETE /device/{deviceId}, scope devices:core) but the provider has no resource for it; treat as a runbook action in the admin console. Everything else needed here is code: policy file, key expiry length, device approval off, user approval on, 'prevent edits in the admin console' (acls_externally_managed_on).

Source: https://api.tailscale.com/api/v2?outputOpenapiSchema=true ; https://api.github.com/repos/tailscale/terraform-provider-tailscale/contents/docs/resources ; https://tailscale.com/docs/reference/tailscale-cli/lock

**8. Cutting off a lost laptop within minutes** (`primary`)

Fast step, possible from any browser including the phone: admin console, Machines, the device's menu, Remove. 'The device will immediately lose connection to all resources in the tailnet.' API equivalents: DELETE /device/{deviceId}; POST /device/{deviceId}/expire ('Mark a device's node key as expired. This will require the device to re-authenticate'). Removal is the stronger of the two. Removal alone is not enough for this laptop, for three documented reasons. (1) 'If device approval is disabled, removed devices can rejoin without admin authorization': anyone who can log in as the owner can re-enrol it, and a stolen laptop may hold a live GitHub browser session, so GitHub sessions must be revoked and the password changed at once. (2) The laptop is a signing node and 'Tailnet Lock keys are stored on the device', so its lock key must be un-trusted from the second signing node: 'tailscale lock remove tlpub:<laptop key>' (default re-signs what that key had signed), or 'tailscale lock revoke-keys' if it may already have been misused; revoke needs co-signatures 'until the number of times you used --cosign exceeds the number of revoked keys'. This is CLI only, so it waits until the owner reaches the other signing node. (3) The laptop also held the SSH keys, the age key and the Tailscale OAuth client secret; those follow the existing workstation-loss runbook, plus revoking the OAuth client in the console. Emergency stop available from a phone: remove the subnet router device itself; all remote access ends for everyone until it is re-enrolled at home.

Source: https://tailscale.com/docs/features/access-control/device-management/how-to/remove ; https://api.tailscale.com/api/v2?outputOpenapiSchema=true ; https://tailscale.com/docs/reference/tailscale-cli/lock ; https://tailscale.com/docs/features/tailnet-lock

**8. Proving afterwards that the laptop has no access** (`primary`)

Evidence available on the free plan: (1) the device no longer appears in the Machines list or in GET /tailnet/{tailnet}/devices; (2) the configuration audit log (all plans, 90 days, GET /tailnet/{tailnetId}/logging/configuration, scope logs:configuration:read) shows the removal and would show any later login, new node, policy change or lock change; (3) on the subnet router, 'tailscale status' no longer lists the peer, 'tailscale lock status' no longer lists the laptop's key as trusted, and 'tailscale lock log' shows the key removal; (4) the policy in Git no longer contains the laptop's address if the host-alias form is used. Not available: network flow logs are not in the Personal plan, so Tailscale gives no record of traffic. Traffic evidence has to come from home: connection logging on the VLAN 30 firewall rules and the SSH and Proxmox login logs on the targets. With the default source NAT on the subnet router every remote connection carries the router's VLAN 30 address, so those logs show that remote access was used, not which tailnet device used it.

Source: https://tailscale.com/docs/features/logging/audit-logging ; https://tailscale.com/pricing ; https://tailscale.com/docs/reference/tailscale-cli/lock ; https://tailscale.com/kb/1019/subnets

**8. Gap: revocation of a removed node under tailnet lock** (`not-verified`)

Neither the tailnet lock page nor the whitepaper describes what happens to the signature of a node that has been removed from the tailnet. The documented revocation tools act on signing keys, not on individual node keys. Whether a removed node's old signature could be replayed by a compromised control plane, and whether a removed signing laptop can re-sign itself after logging in again, could not be verified. This is the reason the lost-laptop procedure must include removing the laptop's lock key and not only removing the device.

Source: https://tailscale.com/docs/features/tailnet-lock ; https://tailscale.com/docs/concepts/tailnet-lock-whitepaper

## The client: Windows 11 with WSL2

### Recommendation

Client side for Phase R, in order of weight:

1. Keep WSL in NAT mode and run Tailscale on Windows only. Do not install it inside WSL, do not use mirrored mode, do not use an exit node.

2. Make the mode explicit and checkable. At home: Tailscale down. Away: Tailscale up with accept-routes on. Add a preflight to the operator session that asks Windows which interface it would use for 10.0.10.10 (Find-NetRoute) and refuses to continue when the answer does not match the mode. There is no automatic mechanism to rely on.

3. Fixed preferences on the laptop, set with 'tailscale set' from a script in Git (scripts/node2): shields-up on, accept-dns off, unattended off, no exit node, key expiry left on. Turn MagicDNS off in the tailnet.

4. Fix MTU on the managed side: MSS clamping on the subnet router, in Git. Treat WSL's automatic MTU lowering as a bonus to confirm in the lab, not as the fix.

5. Before installing Tailscale, close two workstation gaps in pbs-vm.ps1: add a deny for 100.64.0.0/10 to the backup VM's 'nat' ACL, and decide whether the 8007 allow rule should also be tied to the home interface. Add a travel script that asserts the checks listed under question 6.

6. Owner decisions to put in the plan: (a) the laptop's disk is not encrypted and would now carry the node key, and the lock signing key if the laptop is a signing node, outside the house; choose BitLocker, Tailscale's TPM state encryption (EncryptState), or both. (b) whether the laptop is a tailnet-lock signing node at all, or whether signing stays on a device that does not travel.

7. Expect relayed connections on mobile data: usable for ssh and Ansible, slow for large copies. The later cloud instance can serve as a peer relay on the free plan; plan that as part of the add-on, not Phase R.

### Risks

- At home with Tailscale left connected, admin traffic silently takes the tunnel (longest prefix wins over the default route). It still works, but slowly and with the subnet router's address in the hypervisor's logs. Not a breach; an attribution and latency problem that only a preflight check catches.
- The workstation disk is not encrypted (scripts/node2/workstation.ps1:65). Tailscale's node key, and the tailnet-lock key if the laptop signs, sit in C:\ProgramData\Tailscale behind file permissions only. A stolen laptop is a tailnet member until the device is removed.
- The backup VM's 'nat' ACL does not deny 100.64.0.0/10 (scripts/node2/pbs-vm.ps1:373-378). With Tailscale up the VM may reach tailnet devices under the laptop's identity.
- The Windows Firewall allow rule for TCP 8007 from 10.0.10.10 is not bound to an interface. After a subnet router advertises that address, the address no longer proves the path. Shields up and the tailnet policy must cover it.
- The Tailscale interface is always Private in Windows Firewall, and 'Tailscale-In' admits everything addressed to the Tailscale address. Any future listener on 0.0.0.0 is exposed to the tailnet unless shields up stays on.
- The automatic MTU lowering in WSL depends on WSL's behaviour, which can change between releases, and it lowers eth0 to 1280 for all traffic while the Tailscale adapter is connected. If it does not trigger, ssh and TLS from WSL stall on large transfers while ping works.
- Relayed (DERP) paths are the likely normal case on mobile data: single-digit Mbit/s and higher latency. Large uploads to Proxmox from outside are impractical until a peer relay exists.
- Windows shows no captive-portal notification. On hotel or airport Wi-Fi Tailscale simply fails to connect until the portal login is done in a browser.
- JSON output of the CLI is marked 'subject to change', and auto-update of the Windows client would move the version under the scripts. Pin the client version and switch auto-update off, or accept the drift knowingly.
- Mirrored mode, if ever enabled for other reasons, breaks the WSL-range firewall rules for the backup server's management window.

### Open points

- Routing from WSL into the tailnet is recommended by Tailscale but not stated as a guarantee. Lab: with Tailscale up and the route accepted, run from WSL 'ssh 10.0.10.10 true' and on Windows 'Find-NetRoute -RemoteIPAddress 10.0.10.10'; on pve1 confirm the source address is the subnet router's VLAN 30 address.
- WSL's automatic MTU. Lab: 'ip link show eth0' in WSL with Tailscale up, then down, then after sleep and resume. Then 'ping -M do -s 1252 10.0.10.10' (must pass), 'ping -M do -s 1253' (must fail cleanly with 'message too long', not time out), and an scp of a 100 MB file in both directions.
- Whether the Tailscale adapter counts as connected for WSL's MTU calculation while Tailscale is down, and the first WSL release with this behaviour: not verified. The lab check above answers the first; the second needs the WSL release notes.
- Whether plain 'tailscale up' with no flags is accepted after preferences were changed with 'tailscale set', and whether 'tailscale down' survives a reboot and a sign-in: not verified in documentation. Lab: set the preferences, run down, reboot, check 'tailscale status --json' BackendState is Stopped.
- Whether the CLI works when the tray application is not running, and which operations need an elevated prompt: not verified. Lab: run up, down, set, status and 'lock status' from a non-elevated PowerShell with and without the tray application.
- A stable way to read preferences back (ShieldsUp, RouteAll, CorpDNS, ForceDaemon). 'tailscale debug prefs' is what I know of, from memory, not verified and not a stable interface. Lab: confirm the command and its field names on the pinned version.
- Whether a packet with source 10.0.10.10 arriving from the subnet router passes Tailscale's filter on the laptop with shields down. Lab, once, before shields-up is enforced: from the subnet router try TCP 8007 to the laptop's Tailscale address with a forged source; then repeat with shields up. Expect refusal in both cases under a policy that names no laptop destination.
- Whether WinNAT forwards the backup VM's traffic into the Tailscale interface. Lab: from the VM try a tailnet 100.x address before and after adding the 100.64.0.0/10 deny.
- NAT type of both ends. Lab: 'tailscale netcheck' on the subnet router and on the laptop on mobile data; record MappingVariesByDestIP, UDP, nearest DERP region and latency. Then 'tailscale ping <subnet router>' to see direct or relayed, and time a real Ansible run.
- Effect of Windows Firewall 'block all incoming, including allowed apps' on the Public profile on Tailscale's ability to connect: not verified. Lab: enable it on a test network and check 'tailscale status'.
- Tailscale's install path on Windows and the exact name of its network interface: not verified (Tailscale is not installed on this laptop today). Read both after installation and put them in the script as checked values.
- Managing the tailnet's DNS setting (MagicDNS off) from Git, for example through Tailscale's Terraform provider: not researched here; belongs to the tailnet-policy question.
- State encryption on Windows: confirm the laptop has a working TPM 2.0 (Get-Tpm) before setting the EncryptState policy; a TPM reset means re-registering the node.

### Findings

**1** (`primary`)

WSL2 in NAT mode has no Tailscale of its own; Windows NATs its traffic and routes it by the Windows routing table, so an accepted subnet route (for example 10.0.10.10/32) carries WSL traffic into the tailnet. Tailscale's WSL page recommends exactly this layout: 'run Tailscale on the Windows host only, and not inside WSL 2'. Issue #2061 ('MTU issues for WSL2 with NAT by Windows host') shows it working for ssh from WSL, with stalls on large output. I did not find a Tailscale page that states the routing in so many words; it must be proven in the lab. The laptop's source address in the tailnet is its 100.x address; the subnet router then translates to its own VLAN 30 address (SNAT is on by default).

Source: https://tailscale.com/docs/install/windows/wsl2 ; https://github.com/tailscale/tailscale/issues/2061 ; https://tailscale.com/docs/features/subnet-routers

**1** (`primary`)

Accept routes: on by default on Windows, iOS, Android and both macOS app variants; off by default on Linux, BSD and the open-source macOS build. Source code agrees: defaultRouteAll returns true for windows, android, ios. So the Windows client needs nothing extra to accept routes, and a script should set it explicitly rather than rely on the default (tailscale set --accept-routes=true/false). The subnet router container (Linux) does not need accept-routes.

Source: https://tailscale.com/docs/reference/tailscale-cli ; https://tailscale.com/docs/features/client/manage-preferences ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/prefs.go

**1** (`primary`)

MTU. The Tailscale interface is 1280; WSL's eth0 is 1500 on this laptop today (measured: WSL 2.7.3.0, eth0 mtu 1500, Tailscale not installed). The classic failure is: ping and small commands work, ssh/scp/TLS stall on full-size packets (#2061, fixed there with 'ip link set dev eth0 mtu 1280'). Current WSL source lowers this by itself: NatNetworking::UpdateMtu sets the guest MTU to the smallest MTU of all connected Windows interfaces and re-runs on every connectivity change. Once the Tailscale adapter is connected, eth0 should therefore drop to 1280 without any setting. Issue #21659 (opened 2026-10-05) observes eth0 at 1280 on a host with the Windows Tailscale adapter, consistent with this. Whether the adapter counts as 'connected' while Tailscale is down, and since which WSL release this exists, is not verified.

Source: https://raw.githubusercontent.com/microsoft/WSL/master/src/windows/common/NatNetworking.cpp ; https://raw.githubusercontent.com/microsoft/WSL/master/src/windows/common/WslCoreNetworkingSupport.cpp ; https://github.com/tailscale/tailscale/issues/21659 ; local check on the workstation 2026-10-08

**1** (`primary`)

Documented fixes if stalls still appear. (a) Inside WSL: 'ip link set dev eth0 mtu 1280' (from #2061); to persist, /etc/wsl.conf [boot] command= runs a command as root at start (Microsoft documents the key; the MTU use of it is from community write-ups). There is no MTU key in .wslconfig or wsl.conf. (b) On the subnet router: Tailscale's site-to-site page gives 'iptables -t mangle -A FORWARD -o tailscale0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'. This is the fix to put in Git, because it lives on the managed side and covers every client.

Source: https://learn.microsoft.com/en-us/windows/wsl/wsl-config ; https://tailscale.com/docs/features/site-to-site ; https://github.com/tailscale/tailscale/issues/2061

**1** (`primary`)

Mirrored mode is not a reason to change. It does make the MTU correct by construction (the Tailscale interface is mirrored into WSL; #21659 notes a mirrored instance is unaffected), and Microsoft lists 'improved networking compatibility for VPNs'. But it has its own open path-MTU black-hole bug (microsoft/WSL #41419, opened 2026-08-22), and it would break this repository's workstation fences, which are written for NAT mode: pbs-vm.ps1 scopes the management forward to WSL's NAT range 172.16.0.0/12 (line 94, rules at lines 460 and 464). Keep NAT mode.

Source: https://learn.microsoft.com/en-us/windows/wsl/networking ; https://github.com/microsoft/WSL/issues/41419 ; scripts\node2\pbs-vm.ps1:94,460,464

**1** (`primary`)

Do not install Tailscale inside WSL as well: Tailscale states that with both running, traffic from WSL over the host's Tailscale 'will not work due to Tailscale packets not being able to fit in Tailscale packets'. Do not use an exit node on this laptop: with an exit node the Windows client installs a block-all filter set whose Hyper-V/WSL permit is an unimplemented TODO in the source.

Source: https://tailscale.com/docs/install/windows/wsl2 ; https://raw.githubusercontent.com/tailscale/tailscale/main/wf/firewall.go

**2** (`primary`)

At home with Tailscale connected and routes accepted, packets to 10.0.10.10 go through the tailnet, not the home router. Documented: 'On both Windows and macOS, routes are accepted by default' and 'the operating system will prioritize routes with the longest prefix match'. The laptop is in 192.168.1.0/24 and reaches 10.0.10.0/24 only through its default route (0.0.0.0/0), so any advertised prefix, and a /32 most of all, wins. The hypervisor then sees the subnet router's VLAN 30 address. Tailscale's documented workaround (advertise a less specific prefix than the LAN) only helps a client that is directly on the advertised subnet; it cannot help here, because nothing is less specific than a default route.

Source: https://tailscale.com/docs/reference/troubleshooting/network-configuration/lan-traffic-overlapping-subnets

**2** (`primary`)

There is no documented automatic 'same LAN, skip the subnet router' mechanism on Windows. The feature request for it (#1227, opened 2021-01-29) is still open, and #14995 (2025-02-12, open) reports the opposite: Tailscale's route wins even over a directly connected subnet. Source code confirms why: subnet routes are added with route metric 0. Inference, not documented: at home the tunnel would probably run through a DERP relay, because the default-deny between the laptop's VLAN and VLAN 30 blocks a direct UDP path and both sit behind the same carrier NAT.

Source: https://github.com/tailscale/tailscale/issues/1227 ; https://github.com/tailscale/tailscale/issues/14995 ; https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/router/osrouter/ifconfig_windows.go

**2** (`primary`)

Clean ways to get 'home: direct, away: tunnel'. (1) Recommended: Tailscale connected only while away ('tailscale down' at home, 'tailscale up' away). Fewest states, and at home the laptop is not on the tailnet at all. (2) 'tailscale set --accept-routes=false' at home: stays connected (useful for lock signing) but adds a second state to get wrong. (3) Not recommended: a static Windows route to 10.0.10.0/24 via 192.168.1.1; it ties with or loses to Tailscale's metric-0 /32 and, on a foreign network that also uses 192.168.1.0/24, would send admin traffic to a stranger's gateway. Whichever is chosen, make it checkable: 'Find-NetRoute -RemoteIPAddress 10.0.10.10' (cmdlet present on this laptop) returns the interface Windows would use without sending a packet; the operator session can refuse to start when the answer does not match the mode.

Source: https://tailscale.com/docs/reference/tailscale-cli ; local check on the workstation 2026-10-08 (Get-Command Find-NetRoute)

**3** (`primary`)

The CLI talks to the Tailscale service over a local named pipe. Source comment: 'Windows users always have read/write access to the local API if they're allowed to connect', so up, down, set and status work from a non-elevated PowerShell for the logged-in user. Some operations are gated on an elevated token (IsLocalAdmin checks tok.IsElevated()); I did not enumerate which. 'tailscale status --json' is documented as machine-readable; fields in source include BackendState (NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running), Self.KeyExpiry, Peer[].PrimaryRoutes, Peer[].Relay, Health, and tailnet-lock fields. The up page marks JSON output 'subject to change', so pin the client version and test the parser.

Source: https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnserver/server.go ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnserver/actor.go ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/ipnstate/ipnstate.go ; https://tailscale.com/docs/reference/tailscale-cli/up

**3** (`primary`)

Script rules. Use 'tailscale set' for preferences: it changes only what is named. 'tailscale up' with flags is documented as 'Flags are not persisted between runs; you must specify all flags each time'. 'tailscale up' can require a browser login (first login, expired key), so a script must treat NeedsLogin as 'stop and tell the owner', not retry. Tailnet lock: 'tailscale lock sign nodekey:... tlpub:...' must run on a signing node; the page lists Windows as supported. The lock's private key 'is stored on the node that generated it'. When a signed node's key expires, the new key does not need re-signing. Limits: 20 signing nodes. Lock and device approval are mutually exclusive (confirms the correction already made).

Source: https://tailscale.com/docs/reference/tailscale-cli/up ; https://tailscale.com/kb/1226/tailnet-lock

**3** (`primary`)

Unattended mode ('Run unattended', tailscale set --unattended=true, Windows only) keeps Tailscale running as the system after logout and reboot. Without it, 'when the user signs out or the device restarts, Tailscale normally disconnects until a user logs in again'. For a travelling laptop leave it off: the laptop is then on the tailnet only while the owner is logged in. Node keys expire after 180 days by default; keep expiry on for the laptop.

Source: https://tailscale.com/docs/how-to/run-unattended

**3** (`primary`)

Node key storage: C:\ProgramData\Tailscale\server-state.conf ('the key that identifies this computer'; the directory 'contains private keys' and needs administrator rights), plus %LOCALAPPDATA%\Tailscale\prefs.conf. It is machine state behind file permissions, not something unlocked by the user's login. Encryption of this state with the TPM exists but is opt-in on Windows from 1.92.5 (it was on by default in 1.90.2 to 1.92.4); it is switched on with the EncryptState system policy and needs TPM 2.0; a TPM reset means removing and re-registering the node. This matters here because the workstation's disk is not encrypted (workstation.ps1 line 65: 'This disk is not encrypted'), and the laptop would also hold the tailnet-lock signing key.

Source: https://tailscale.com/docs/concepts/windows-config-and-log-files ; https://tailscale.com/kb/1596/secure-node-state-storage ; scripts\node2\workstation.ps1:63-67

**4** (`primary`)

Expect relayed connections most of the time. Tailscale's matrix: Easy NAT + Hard NAT = relayed; Hard + Hard = relayed; only Easy + Easy (or one side without NAT) is direct. Home is behind carrier NAT and mobile data is carrier NAT, so a direct path needs both carriers to be 'easy', which cannot be assumed. Check each side with 'tailscale netcheck' (MappingVariesByDestIP true = hard). If UDP is blocked, traffic falls back to DERP over HTTPS on TCP 443 and still works. Captive portals: detected since v1.72, but notifications exist only on macOS and iOS; on Windows the hint appears in 'tailscale status' health output. Log in to the portal in a browser first.

Source: https://tailscale.com/docs/reference/device-connectivity ; https://tailscale.com/docs/reference/faq/firewall-ports ; https://tailscale.com/docs/integrations/captive-portals

**4** (`primary`)

Throughput and latency on DERP: Tailscale publishes no cap, only that DERP servers 'limit throughput to ensure fairness' and add latency. One Tailscale-published measurement (2026-01-26, India to the USA, carrier NAT): 2.2 Mbit/s and 452 ms through DERP, against 27 to 35 Mbit/s and about 300 ms through a peer relay. So plan for single-digit Mbit/s and a latency equal to the detour through the nearest DERP region. That is fine for ssh and for Ansible (many small round trips; slower, not broken), poor for large file copies or ISO uploads to Proxmox. The lab's own figure must be measured with 'tailscale ping' and 'tailscale netcheck'.

Source: https://tailscale.com/blog/peer-relays-international-networks ; https://tailscale.com/docs/reference/troubleshooting/poor-performance-tailnet ; https://tailscale.com/docs/reference/connection-types

**4** (`primary`)

Peer relays help and are on the free plan: 'Peer Relays are available on all Tailscale plans, including our free Personal plan' (2026-02-18). A relay needs Tailscale 1.86 or later, 'tailscale set --relay-server-port=<port>', a UDP port reachable by the other devices, and a grant with the capability tailscale.com/cap/relay. Nothing at home can offer a reachable UDP port behind carrier NAT, so the relay would be the later cloud instance with a public address. That gives the Oracle add-on a concrete third job. Tailscale tries direct, then peer relay, then DERP.

Source: https://tailscale.com/blog/peer-relays-ga ; https://tailscale.com/docs/features/peer-relay ; https://tailscale.com/docs/reference/connection-types

**5** (`primary`)

Windows Firewall treatment, from source. The client sets its interface's network category to Private (unless already Private or Domain) and adds two rules: 'Tailscale-In' (inbound, allow, localip = the Tailscale addresses, profile=private,domain) and 'Tailscale-Process' (inbound UDP for the program, profile=any). So Windows Firewall admits any inbound connection addressed to the laptop's Tailscale address unless an explicit block rule matches. A request to install as Public instead is open (#14708). A portproxy listening on 0.0.0.0 also listens on the Tailscale address.

Source: https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/router/osrouter/ifconfig_windows.go ; https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/router/osrouter/router_windows.go ; https://github.com/tailscale/tailscale/issues/14708

**5** (`repository`)

The forward on 0.0.0.0:8007 is covered today by the repository's own block rule: 'homelab-pbs1-8007-others' blocks TCP 8007 from every address except 10.0.10.10, on every profile and interface, and Microsoft documents that 'explicit block rules take precedence over any conflicting allow rules'. So a tailnet peer at a 100.x address is blocked. One gap remains: the allow rule 'homelab-pbs1-8007' admits source 10.0.10.10 on any interface. Once a subnet router advertises 10.0.10.10/32 and the laptop accepts it, a packet with that source can arrive through the tunnel from the subnet router. Whether Tailscale's own filter would pass it depends on the tailnet policy; I did not find a page that states the source check, so treat it as open and close it three ways: shields up, a policy with no rule whose destination is the laptop, and the travel script removing the forward.

Source: scripts\node2\pbs-vm.ps1:456-462,494 ; https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules

**5** (`primary`)

Accept nothing inbound from the tailnet: 'tailscale set --shields-up' (tray: untick 'Allow incoming connections'). Documented as 'Block incoming connections from other devices on your Tailscale network'; the preference's source comment says 'block all incoming connections, regardless of the control-provided packet filter'. Outgoing connections, including through a subnet router, are not affected.

Source: https://tailscale.com/docs/features/client/manage-preferences ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/prefs.go

**5** (`repository`)

Hyper-V and WinNAT. I found no documented interference with Hyper-V switches or WinNAT when no exit node is used. Address plans do not collide: Tailscale uses 100.64.0.0/10, the NAT network is 10.0.98.0/29, the direct link 10.0.99.0/29, WSL 172.16.0.0/12; connected /29 routes beat anything advertised as long as the subnet router advertises only the admin /32s. New gap found in the repository: the backup VM's port ACL on the 'nat' adapter denies 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16 but not 100.64.0.0/10. With Tailscale up, the VM's NATed traffic could reach tailnet devices at their 100.x addresses under the laptop's identity. Add a deny for 100.64.0.0/10 before Tailscale is installed. Whether WinNAT really forwards into the Tailscale interface is not verified.

Source: scripts\node2\pbs-vm.ps1:373-378 ; https://raw.githubusercontent.com/tailscale/tailscale/main/wf/firewall.go

**6** (`secondary`)

Profile on public Wi-Fi: Windows 11 sets a newly joined network to Public by default (Microsoft support page, read through a search summary). On this laptop today the home wired network is Private and the two Hyper-V host adapters are pinned Public. The Tailscale interface will be Private regardless of the Wi-Fi's profile, so 'Public profile' alone does not protect the Tailscale side; shields up does.

Source: https://support.microsoft.com/en-us/windows/make-a-wi-fi-network-public-or-private-in-windows-0460117d-8d3e-a7ac-f003-7a0da607448d ; local check on the workstation 2026-10-08 (Get-NetConnectionProfile)

**6** (`primary`)

Checks a travel script can assert from PowerShell (all cmdlets exist on this laptop unless marked). Firewall: Get-NetFirewallProfile shows all three profiles Enabled with inbound Block. Networks: Get-NetConnectionProfile shows every physical connected interface as Public. Lab residue: (Get-VM pbs1).State is Off; 'netsh interface portproxy show v4tov4' is empty; the homelab-* block rules still exist (Get-NetFirewallRule -Name 'homelab-*'). Listeners: Get-NetTCPConnection -State Listen compared with a short allowlist. Remote entry points: Get-Service sshd absent or stopped; Remote Desktop off; file-sharing rules not enabled on Public. WSL: Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' shows Enabled and inbound Block. Session: operator session closed (just session-end) so no decrypted key is in memory. Tailscale: status --json BackendState; preferences ShieldsUp true, CorpDNS false, ForceDaemon false, no exit node, no advertised routes, RunSSH false; key expiry date; 'tailscale lock status'. Route: Find-NetRoute -RemoteIPAddress 10.0.10.10 points at the Tailscale interface when away. Disk: Get-BitLockerVolume (needs elevation).

Source: https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall ; https://raw.githubusercontent.com/tailscale/tailscale/main/ipn/prefs.go ; scripts\node2\pbs-vm.ps1

**7** (`primary`)

MagicDNS is on by default for tailnets created on or after 2022-10-20, so a new tailnet will have it on. For this use (targets by IP, one user) turn it off in the tailnet's DNS page, configure no nameservers, and set 'tailscale set --accept-dns=false' on the laptop as a second guard. With it on, the Windows client adds NRPT rules for its suffixes and a search domain on its interface (source comments).

Source: https://tailscale.com/docs/features/magicdns ; https://raw.githubusercontent.com/tailscale/tailscale/main/net/dns/manager_windows.go

**7** (`primary`)

Effect on WSL's resolv.conf. Older Windows clients rewrote /etc/resolv.conf and added 'generateResolvConf = false' to /etc/wsl.conf in each distro (#2815, 2021, closed). In current source that code runs only when the debug environment switch TS_DEBUG_CONFIGURE_WSL is set, so it is off by default; the release in which this changed is not verified. Indirect effect: this laptop's WSL uses DNS tunnelling (resolv.conf has 'nameserver 10.255.255.254' and 'search lan', copied from Windows; measured today). Windows therefore answers WSL's queries, and any Tailscale DNS rule or search domain accepted on Windows would also apply inside WSL. With accept-dns off nothing changes. The architecture also records dnscrypt-proxy on this workstation, a further reason to keep Tailscale out of its DNS.

Source: https://raw.githubusercontent.com/tailscale/tailscale/main/net/dns/manager_windows.go ; https://github.com/tailscale/tailscale/issues/2815 ; https://learn.microsoft.com/en-us/windows/wsl/wsl-config ; local check on the workstation 2026-10-08 ; docs\ARCHITECTURE.md:382

## What changes in this repository

### Recommendation

Adding VLAN 30 is a small, purely additive change in six repository files plus documentation, and it can be done without ever touching the rules that admit the workstation at home.

Files to change:
- Router: `roles/openwrt_config/templates/router-m30/network.j2` (bridge-vlan 30 tagged on lan1, interface `remote` 10.0.30.1/24), `firewall.j2` (zone `remote` in the zone loop, `Router-DNS-remote`, rules E15 to E18 with the subnet router's address as `src_ip`), `dhcp.j2` (`config dhcp 'remote'`, ignore).
- Hypervisor: `playbooks/group_vars/proxmox.yaml` (`pve_guest_vlans`, a variable for the remote address, one `pve_acls` row for `/sdn/zones/localnetwork/vmbr0/30`), `roles/pve_host/defaults/main.yaml` (one `pve_host_fw_rules` row, tcp 22 and 8006).
- Access points: `templates/access-point/firewall.j2` (one SSH rule).

Three things the plan must not miss:
1. Replace `pve_guest_vlans | first` in the ACL path (proxmox.yaml line 95) with explicit paths in the same pull request. Otherwise adding 30 in front of 50 moves the OpenTofu token's network grant to VLAN 30 and the play deletes the VLAN 50 grant.
2. Add 10.0.30.0/24 to the X10 drop loop in `roles/pve_host/tasks/firewall.yaml`, and never give the hypervisor an address in VLAN 30, not even for a test. Probe from inside the container with `pct exec` instead.
3. The hypervisor firewall has no automatic revert (only the bridge change has one). Run `just pve-apply --check --diff` first and leave the E2 row alone.

Order: backups and zero-drift check; documentation and decision; router (one guarded apply, a few seconds of Wi-Fi interruption, from the wired workstation); hypervisor; access points one at a time with the normal apply (the two-device procedure is not needed); container; tests; gate record.

Decisions the plan should put to the owner, with my defaults:
- Subnet router address: one static address in 10.0.30.0/24 (any; for example .10).
- Router SSH from remote at 10.0.30.1 only, pinned with `dest_ip`; 192.168.1.0/24 is never advertised into the tailnet.
- E18 egress: tcp 80, 443 and udp 3478 only (connections may be relayed, slower), or also udp to any port (direct connections possible). I would start narrow and widen only if relayed speed is a problem.
- Servers rows (E17): write them now, as E3 was written before its targets existed.
- Pool and token: reuse `terraform@pve` with one more ACL row (fewest parts), or a separate pool for the container. I would reuse the token and add a pool only if the role is extended anyway.
- State the phase order openly: creating the container with OpenTofu before Phase 5 makes it the first real state and pulls backlog B29 and B31 forward.

### Risks

- ACL trap: `pve_guest_vlans | first` (playbooks/group_vars/proxmox.yaml:95). With [30, 50] the next `just pve-apply` grants the OpenTofu token VLAN 30 and removes its VLAN 50 grant.
- Hypervisor firewall changes have no revert timer. A bad host.fw is recovered at the console of Node 1 only.
- If the hypervisor ever holds an address in 10.0.30.0/24, pve-firewall's built-in management set opens SSH, the web interface, console and migration ports to the whole remote subnet unless an X10 drop for that subnet is in place.
- The router apply changes `network`, so the bridge and Wi-Fi restart: a short interruption for the whole house. It must run from the wired workstation at home.
- A router apply run over the remote path can be confirmed wrongly: the workstation-side health checks would test the laptop's own internet, not the home router. A locked-out router needs failsafe mode on site.
- Reinstalling or rebooting the hypervisor while away removes or interrupts the only remote path; after a reinstall the container does not exist until someone at home recreates it.
- The zone lists in router firewall.j2 are literal in five separate loops. Adding `remote` to the zone loop but not to the DNS loop leaves the node unable to resolve the Tailscale control plane (no lockout, but the phase stalls).
- A token cannot set device passthrough or container feature flags other than nesting (root@pam only). If the Tailscale container needs /dev/net/tun handed in, the 'no root@pam in automation' rule and the container design collide.
- With the default source rewrite on the subnet router, the lab firewalls cannot tell tailnet devices apart; a mistake in the tailnet policy admits any tailnet device to every E15-E17 target. Keys and second factors on the targets remain.
- 192.168.1.0/24 is common on public networks. If the router's 192.168.1.53 or the trusted LAN were advertised into the tailnet, remote sessions could reach the wrong machine or break local connectivity on the foreign network.
- Memory headroom after the container is about 1.67 GiB against the 1.5 GiB gate: about 0.17 GiB of margin on a host whose idle use has varied between 1.55 and 1.9 GiB.

### Open points

- Whether an unprivileged container on Proxmox VE 9.2 has /dev/net/tun without extra configuration, and whether Tailscale's subnet routing works in userspace mode without it: not verified. Lab check: create a throwaway unprivileged container with the token, look for /dev/net/tun, start tailscaled and advertise a route.
- Whether IP forwarding can be switched on inside an unprivileged container while the host keeps net.ipv4.ip_forward=0: not verified (expected yes, the setting is per network namespace). Lab check: `sysctl -w net.ipv4.ip_forward=1` inside the container, then `sysctl net.ipv4.ip_forward` on the host must still read 0.
- Whether `ifreload -a` after adding a VLAN to bridge-vids interrupts existing traffic on vmbr0: not verified for this exact change (the Phase 3 VLAN-aware change did not drop SSH). The 180 s revert timer covers it; watch a ping during the apply.
- How pve-firewall treats a malformed rule line in host.fw (skips the line or refuses the whole set): not verified; the documentation only says `pve-firewall status` shows warnings. Lab check is not advisable on the live host; rely on the dry run and `pve-firewall compile` output after the change.
- The inventory address of router-m30 was not read (private file, values out of scope). The public tree implies 192.168.1.53 (`just luci`, backup-fences.sh). Confirm it, and decide how Ansible addresses the router remotely (override of ansible_host to 10.0.30.1 plus a HostKeyAlias, as pbs1 already uses).
- Whether direct (not relayed) Tailscale connections form through the ISP's carrier-grade NAT plus the router's own NAT: not verifiable from the repository. Lab check: `tailscale status` and `tailscale ping` from the laptop on mobile data, with and without the wide UDP egress row.
- Route precedence on the laptop when it is at home with the Tailscale client on (tailnet route versus the home default route, on Windows and inside WSL2 with NAT networking): not verified. Lab check: `tracert 10.0.10.10` at home with the client on and off, and the source address seen in the hypervisor's SSH log.
- That an LXC needs no NTP path because it uses the host clock is reasoning, not read in a source today. Lab check: `timedatectl` inside the container.
- Whether the container template download through the API needs a privilege beyond Datastore.AllocateTemplate on /storage/local (ARCHITECTURE already flags Sys.AccessNetwork as a possible need for Phase 5): not verified. Lab check: the first `tofu apply` with the token; record the result with backlog B31.
- Tailnet lock details beyond what was read today (signing a rebuilt node, pre-signed auth keys in practice) were read only as a summary of the Tailscale page; the exact commands belong to the Tailscale research question and should be rehearsed once before the gate.
- The pct manual page and the pveum chapter did not state the container-creation permissions or the SDN ACL path; those findings rest on the pve-container and pve-guest-common source on the master branch, not on the 9.2 release tag. Lab check: read back with `pveum user token permissions terraform@pve tofu` after the ACL change.

### Findings

**1 Router: network files and variables** (`repository`)

Three managed files change on router-m30, all in infrastructure\ansible\roles\openwrt_config\templates\router-m30\. No variable exists for VLANs or zones: they are literal in the templates, so the change is template edits (plus, by choice, one new Jinja `set` for the subnet router's address).

(a) network.j2: add a named section `config bridge-vlan 'vlan30'` (device br-lan, vlan 30, `list ports 'lan1:t'`), same form as vlan50 at lines 41-44. Add `config interface 'remote'` (device br-lan.30, proto static, `list ipaddr '10.0.30.1/24'`, `option delegate '0'`), same form as `servers` at lines 73-77. Update the comment at lines 21-25 (lan1 = management untagged, remote and servers tagged). VLAN 30 goes on lan1 only; lan2/lan3 (openwrt_ap_trunk_ports) and lan4 do not carry it.

(b) A router address IS needed. The design table shows '-' for VLAN 30 (ARCHITECTURE.md line 317). The router is the only layer-3 device between zones, so without 10.0.30.1 the container has no gateway to the WAN or to the admin targets, and fw4 has no interface to bind the zone to. The table row must become '.1'.

(c) dhcp.j2: add `config dhcp 'remote'` with `option interface 'remote'` and `option ignore '1'`, as for mgmt and servers (lines 50-56). No pool: the design uses static addresses for infrastructure.

wireless, system, dropbear, uhttpd and smartdns do not change. Router dropbear has no Interface option (dropbear.j2), so it already listens on the new address; the firewall decides.

Source: infrastructure/ansible/roles/openwrt_config/templates/router-m30/network.j2:13-89; dhcp.j2:50-56; dropbear.j2:3-6; playbooks/group_vars/openwrt_routers.yaml:9-18; docs/ARCHITECTURE.md:317,334

**1 Router: firewall zone, rule style, free exception numbers** (`repository`)

File: templates/router-m30/firewall.j2. Zones are created by a literal loop at line 22 (`for z in ['lan','mgmt','servers','iot','guest']`) with input/forward REJECT; add 'remote' there. The header comment (lines 1-4) says 'E1 to E14' and must be updated.

How rules are written today: addresses are Jinja `set` lines at the top (workstations, pve1, access_points, k8s_api, k8s_nodes, k8s_workers, gw_household, gw_admin; lines 8-15). Each exception is an anonymous `config rule` whose `option name` is `E<n>-<source>-to-<target>` (for example 'E2-workstation-to-pve1'), with `option src`, `list src_ip` in a loop, `option dest`, `option dest_ip`, `option proto`, `option dest_port 'a b'`, `option target 'ACCEPT'`. One E number may cover several rules (E2 has three, E3 three, E5 two). Zone-wide allows are named `config forwarding 'e8_iot_to_wan'`. Services the router offers a zone are not exceptions: they are named `Router-DNS-<zone>`, `Router-NTP-<zone>`, `Router-Ping-<zone>`, `Router-DHCP-<zone>`, each from its own literal zone loop (lines 65-102).

Free numbers: E1-E14 are used (E10 is not on the router), so E15 is the next free E. A natural mapping that mirrors E1-E3 (the plan decides): E15 remote -> router input tcp 22; E16 remote -> mgmt (pve1 tcp 22 and 8006; 10.0.10.2 and .3 tcp 22; optionally ping); E17 remote -> servers (10.0.50.10:6443, .11 and .21:50000, 10.0.50.201:443); E18 remote -> WAN. Every rule should carry `option src_ip` = the one subnet-router address (new `{% set remote_router = '10.0.30.x' %}`), in line with the 'host-scoped rules' principle. Precedent: the E3 rules are already in the template although their targets do not exist yet, so E17 can be written now or deferred to Phase 5; either is consistent.

Router SSH from the remote zone: a rule with `src` and no `dest` is an input rule and matches by ingress zone, so it would admit SSH to any router address (10.0.30.1, 10.0.10.1, 192.168.1.53). Adding `option dest_ip '10.0.30.1'` pins it to the VLAN 30 address; no remote -> lan forwarding is needed for router SSH.

Source: infrastructure/ansible/roles/openwrt_config/templates/router-m30/firewall.j2:1-102,103-286; docs/components/openwrt.md:16-40; https://openwrt.org/docs/guide-user/firewall/firewall_configuration (rule classification by src/dest, read today)

**1 Router: DHCP, DNS, NTP for the remote zone; what remote -> WAN needs** (`primary`)

DHCP: not needed (static address set when the container is created); do not add 'remote' to the Router-DHCP loop.
DNS: needed. The node must resolve the Tailscale control and relay names and the package mirrors. Add 'remote' to the Router-DNS loop (firewall.j2 line 75). No Force-DNS redirect is needed: that loop covers client networks only, and with default reject and no rule to WAN port 53 the router is the only resolver the zone can reach (same posture as mgmt). dnsmasq has `localservice '1'`, so it answers 10.0.30.0/24 once the interface exists.
NTP: not needed for a container (it uses the hypervisor's clock; this is reasoning, not read in a source today). It would be needed only for a full VM.
Ping of the router: optional (Router-Ping loop, line 93); useful as a health check.

remote -> WAN in E-row style, source pinned to the subnet router: tcp 443 (control plane and DERP relays; this alone is enough to work, relayed); udp 3478 (STUN); tcp 80 (captive-portal detection, optional per Tailscale, and Debian package mirrors, as in E11); and, only if direct peer-to-peer paths are wanted, udp to any destination port (Tailscale documents WireGuard as udp from source port 41641 to *:*). Decision for the plan: 'tcp 80 443 + udp 3478' (least privilege, connections may stay relayed) or the same plus 'udp to any port' (direct paths possible; a wider row). The WAN zone already has `masq '1'`, so nothing else changes. Between internal zones there is no masquerading, so the 10.0.30.x source is preserved towards mgmt and servers, which meets the 'never source-NATed into the management network' condition on the router side.

Source: firewall.j2:31-39,65-102,288-308; dhcp.j2:16; https://tailscale.com/kb/1082/firewall-ports (read today); docs/research/2026-10-05-platform-research.md:107

**2 Hypervisor: guest VLANs, interfaces file, guarded change** (`repository`)

Guest VLANs are the list `pve_guest_vlans: [50]` in infrastructure/ansible/playbooks/group_vars/proxmox.yaml line 26. templates/interfaces.j2 line 19 renders it as `bridge-vids {{ pve_guest_vlans | join(' ') }}`. Adding 30 therefore changes /etc/network/interfaces and goes through tasks/network.yaml: syntax check with `ifup --syntax-check`, transient timer `homelab-net-revert` armed for `pve_host_net_revert_seconds` (180, role defaults line 21), `ifreload -a` detached, `wait_for_connection`, then an assert that every VLAN in `pve_guest_vlans` appears in `bridge vlan show dev enp3s0` and that vmbr1 has its address, and only then the timer is stopped. A dry run (`just pve-apply --check --diff`) only reports that the file would be replaced. In Phase 3 the same path was used for the VLAN-aware change and the SSH session did not drop.

TRAP (must be fixed in the same pull request): the OpenTofu token's network grant is written as `/sdn/zones/localnetwork/vmbr0/{{ pve_guest_vlans | first }}` (proxmox.yaml line 95). If the list becomes [30, 50], the grant silently moves to VLAN 30 and the play's 'Remove entries that Git no longer grants' task deletes the VLAN 50 entry for terraform@pve and its token. With [50, 30] nothing moves, but that depends on list order. Replace `| first` with explicit paths (one ACL row per VLAN, or a named variable).

Source: infrastructure/ansible/playbooks/group_vars/proxmox.yaml:24-28,79-97; roles/pve_host/templates/interfaces.j2:12-19; roles/pve_host/tasks/network.yaml:16-172; roles/pve_host/defaults/main.yaml:19-21; roles/pve_host/tasks/access.yaml:144-173; docs/phases/phase-3.md:31

**2 Hypervisor: host firewall, X10 drops, IPv6, sshd** (`repository`)

Rule list: `pve_host_fw_rules` in roles/pve_host/defaults/main.yaml lines 33-49 (items: comment, source, proto, dport). Add one item, for example comment 'E16 remote administration: SSH and web interface', source = a new variable in group_vars/proxmox.yaml holding the single 10.0.30.x address, proto tcp, dport '22,8006'. tasks/firewall.yaml renders these as `IN ACCEPT -source ... -dport ...` lines before the X10 drops, so order is correct.

X10 drops: the loop covers only `pve_mgmt_network` and `pve_p2p_network` (firewall.yaml lines 39-41). The host has no address in VLAN 30, so 10.0.30.0/24 is not one of its local networks and pve-firewall's built-in management set does not include it; the rest of 10.0.30.0/24 falls to policy DROP. No change is strictly required. Recommended anyway: add 10.0.30.0/24 to the drop loop, because the moment the host is given any address in VLAN 30 (for example a temporary test interface, as Phase 2 did for VLAN 50), the built-in set would open 22, 8006, 3128, 5900-5999 and 60000-60050 to the whole remote subnet.

Ping: the two ICMP accepts (router, workstations) are literal lines in tasks/firewall.yaml lines 30-31, not part of the variable; a ping from the remote address needs a template edit there.

IPv6: host.fw sets `ndp: 0`; the new rule is IPv4 by address. Nothing changes.

No revert guard exists for the host firewall: firewall.yaml writes host.fw in place and the handler runs `pve-firewall restart` at the end of the play. Keep the E2 row untouched and run `--check --diff` first; recovery from a bad rule set is the console.

sshd already permits it: `ListenAddress {{ pve_mgmt_address }}` (10.0.10.10) and `AllowUsers ops` with no host pattern (tasks/ssh.yaml lines 7-11). A routed connection from 10.0.30.x to 10.0.10.10:22 needs no sshd change. Path: container -> VLAN 30 tagged -> router -> VLAN 10 -> host; the host does not route (ip_forward 0, tasks/system.yaml) so the router's E16 rule is always in the path.

Source: roles/pve_host/defaults/main.yaml:32-49; roles/pve_host/tasks/firewall.yaml:11-62; roles/pve_host/tasks/ssh.yaml:2-16; roles/pve_host/tasks/system.yaml:8-17; roles/pve_host/handlers/main.yaml:43-46; https://pve.proxmox.com/pve-docs/chapter-pve-firewall.html (management set and its ports, read today)

**2 Hypervisor: pool, ACL path and privileges for a container on VLAN 30; unknown ACL entries** (`primary`)

Pool: the role knows exactly one pool, `pve_pool: talos` ('Talos VMs, managed by OpenTofu'; access.yaml lines 47-51). A remote-access container either goes into that pool (misnamed) or the role is extended to a list of pools; a second pool needs its own ACL row.

What the API checks for creating a container (pve-container source, read today): VM.Allocate on /vms/{vmid} or /pool/{pool}; Datastore.AllocateSpace on the storage; for a privileged container Sys.Modify on '/'; for each NIC `check_bridge_access`, which checks SDN.Use on `/sdn/zones/localnetwork/vmbr0/30` when a tag is set (and on the bridge itself only when no tag is set); VM.Config.Network for net*, VM.Config.CPU, VM.Config.Memory, VM.Config.Disk, VM.Config.Options for the rest. `TerraformProvisioner` already holds all of these, plus Datastore.AllocateTemplate on /storage/local for the template. So for an unprivileged container the existing role is enough and the only new ACL row is `{path: /sdn/zones/localnetwork/vmbr0/30, role: TerraformProvisioner, user: terraform@pve}` in `pve_acls` (tokens inherit their user's rows through access-tokens.yaml). Least-privilege alternative: a separate user/token/role for the remote-access guest with its own pool; then `pve_users`, `pve_tokens`, `pve_roles`, `pve_acls` all gain entries and `just pve-tokens` issues the token into private/proxmox/tokens.sops.yaml.

Limits a token cannot pass (same source): `dev*` (device passthrough), `hookscript` and every `features` flag except `nesting` are root@pam only. If Tailscale in an unprivileged container needs /dev/net/tun handed in, the token cannot configure that; see open points.

Unknown ACL entries: for users named in `pve_users` plus `pve_admin_user` and their tokens, any entry not in `pve_acls` is deleted on the next `just pve-apply` (after the wanted ones are added). Entries of other principals (root@pam, groups) are left alone. A user in the pve realm or a token that Git does not name stops the play. So a grant added by hand for VLAN 30 disappears on the next run; it must be in Git.

Source: playbooks/group_vars/proxmox.yaml:38-106; roles/pve_host/tasks/access.yaml:47-51,97-173; roles/pve_host/tasks/access-tokens.yaml:15-68; https://raw.githubusercontent.com/proxmox/pve-container/master/src/PVE/API2/LXC.pm; https://raw.githubusercontent.com/proxmox/pve-container/master/src/PVE/LXC.pm; https://raw.githubusercontent.com/proxmox/pve-guest-common/master/src/PVE/GuestHelpers.pm (check_vnet_access)

**3 Access points** (`repository`)

One file: templates/access-point/firewall.j2 (shared by ap1 and ap2). It has one zone (mgmt, input REJECT) and two rules with literal addresses: 'E2-workstation-ssh' (tcp 22 from 192.168.1.196 and .197) and 'Ping-from-router-and-workstation'. Add one rule, for example 'E16-remote-ssh': src mgmt, src_ip = the subnet-router address, tcp 22, ACCEPT. The address is literal today; a shared variable is a tidy-up, not a need. Nothing else changes on the access points: VLAN 30 is not carried to them (network.j2 untouched), dropbear has no interface binding, and replies leave by their existing gateway 10.0.10.1. The router side is the E16 forward rule to 10.0.10.2 and .3.

Procedure: this is NOT the two-device cut-over. The uplink trunk does not change, so each access point can verify itself. Use the normal guarded apply, one device at a time: `just openwrt-apply ap1`, then `just openwrt-apply ap2` (the play is `serial: 1`; revert after `openwrt_config_revert_seconds` = 300 s unless the fresh login, the compare with Git and the health checks `ping 10.0.10.1`, `nslookup openwrt.org 10.0.10.1`, `fw4 check` pass). Only `firewall` changes, so activate.sh restarts the firewall only: no network restart and no Wi-Fi drop.

For reference, the two-device procedure of Phase 4 (not needed here): access point applied unverified with a 600 s timer (`openwrt_config_verify=false`, `openwrt_config_revert_seconds=600`), router applied unconfirmed (`openwrt_config_confirm=false`, 300 s), then `just openwrt-confirm <ap>`, then `just openwrt-confirm router-m30`. The `just openwrt-apply` recipe passes only `target`, so those extra variables need `bash scripts/ops/play.sh openwrt-apply -e target=... -e ...` directly.

Source: roles/openwrt_config/templates/access-point/firewall.j2:1-37; templates/access-point/network.j2:47-53; playbooks/group_vars/openwrt_aps.yaml:15-20; roles/openwrt_config/defaults/main.yaml:26-48; roles/openwrt_config/tasks/apply.yaml; files/activate.sh:23-44; justfile:80-86; docs/phases/phase-4-plan.md:37-46

**4 Order of changes and guards** (`repository`)

Every change is additive; no existing workstation rule (E1-E3) is edited, so the home path stays as it is throughout.

0. Before anything: `just openwrt-check openwrt` and `just pve-apply --check --diff` report zero drift; fresh SOPS-encrypted backups of the three OpenWrt devices in private/openwrt/backups/<date>-pre-phase-r/ (convention of steps 2.0 and 4.0). Guard: none needed, read-only.
1. Design text, decision and exception rows merged by pull request (no device change).
2. Router, one guarded apply of network + firewall + dhcp together (`just openwrt-apply router-m30`). Guard: snapshot in RAM, 300 s revert with a per-change token, fresh login, compare with Git, device health checks (WAN gateway ping, DNS, `fw4 check`) and workstation checks (curl, getent). Effect: `network` changed, so activate.sh runs `/etc/init.d/network restart`, which rebuilds the bridge and restarts Wi-Fi: a few seconds of interruption for the whole house, as in Phase 2 steps 2.5-2.6. Do it from the wired workstation.
3. Hypervisor, `just pve-apply`: bridge-vids gains 30 under the 180 s revert timer; then the firewall row, the pool/ACL rows. Guard: the network revert timer covers the bridge only. The firewall write and `pve-firewall restart` have no revert; the guard there is the dry run and leaving the E2 row untouched; fallback is the console. Fix the `| first` ACL trap in this same change.
4. Access points, firewall only, ap1 then ap2. Guard: the 300 s device revert each.
   Steps 2, 3 and 4 are independent of each other; this order lets each be tested before the next.
5. Container in VLAN 30 and the Tailscale join (outside this question). No lockout risk for the home path.
6. Deny and allow tests, then the gate record.

Not to be done over the remote path: (a) any router apply that changes `network` or `firewall`: the path itself drops, and the workstation-side health checks (`openwrt_config_health_local_commands`) would test the laptop's mobile internet, not the home router, so a broken home network could be confirmed; recovery of the router needs failsafe mode in the house. (b) Router and access-point firmware updates and the two-device cut-over. (c) Hypervisor bridge changes and anything that edits the remote row in host.fw (no revert on the firewall). (d) `just pve-media prepare/reboot` (reinstall) and reboots for upgrades: the container that carries the access is on that host; after a reinstall it does not exist until OpenTofu recreates it, which needs access. (e) Changes to the container, its tailnet policy or node signing. (f) `just openwrt-ssh-keys` is guarded by its own 120 s restore but still belongs at home. Read-only checks, `pve-apply` runs that touch neither bridges nor firewall, and later `kubectl`/`talosctl` are reasonable remote work.

Source: roles/openwrt_config/tasks/apply.yaml:42-122; tasks/confirm.yaml; files/activate.sh:23-29; files/revert.sh; roles/pve_host/tasks/network.yaml; roles/pve_host/tasks/firewall.yaml:52-62; roles/pve_host/tasks/main.yaml:17-28; roles/openwrt_config/tasks/ssh_keys.yaml:50-63; docs/phases/phase-2-plan.md:24-49; docs/components/proxmox.md:88-100

**5 Tests and probe vantage points** (`repository`)

`just test-fences` runs scripts/tests/backup-fences.sh, which is only about the backup path. It is the only scripted deny test; the matrix tests of Phases 2, 3 and 4 were run by hand and recorded as tables (From | Test | Expected | Result). No CI job renders the OpenWrt templates (scripts/tests/render-templates.py covers the answer files only); the first real check of a firewall template is `just openwrt-check`, which renders, parses with `uci` on the device and prints the diff.

Vantage points that exist: the hypervisor (ssh ops@10.0.10.10, bash /dev/tcp probe; a management-zone source); the router (dbclient probe with a watchdog, reads answered/silent); WSL on the workstation; the backup VM (only while the management window is open); by hand, an access point with dbclient (Phase 3) and temporary clients: a VLAN 50 client on Node 1 (Phase 2) and a guest-VLAN address on ap1 (Phase 4); phones.

New vantage point needed: inside the container, reached without any network path as `ssh ops@10.0.10.10 sudo pct exec <vmid> -- bash -s`, which fits the script's `run_on` helper. Do not create a VLAN 30 interface with an address on the hypervisor for testing (see the X10 note in finding 2).

Probes to add (new section in backup-fences.sh, or a new scripts/tests/remote-fences.sh with a thin `just` recipe; the justfile keeps recipes to one line and CI runs shellcheck and shfmt on scripts):
- From the container, must be open: 10.0.10.10 tcp 22 and 8006; 10.0.10.2 and .3 tcp 22; 10.0.30.1 tcp 22; router DNS; internet tcp 443.
- From the container, must be closed: 10.0.10.10 on 9100, 9633, 3128, 111; 10.0.10.1 and 192.168.1.53 tcp 22 if E15 is pinned to 10.0.30.1; the workstation's two addresses on 445, 3389, 8007, 2222; another trusted host; 10.0.60.10 and 10.0.60.182 (IoT); 10.0.50.200 tcp 443 (household listener, not a target); the guest network; a public resolver on port 53; an arbitrary internet port such as tcp 22 or 25.
- 'One address only': the same allow probes from a second address in 10.0.30.0/24 added temporarily inside the container must all fail, at the router and at the hypervisor.
- Towards the zone: from the hypervisor (mgmt), from WSL at home (trusted) and from a guest or IoT client, 10.0.30.x answers nothing.
- Both address families, as earlier gates did: no router advertisement and no IPv6 address or route in VLAN 30.
- From the laptop on mobile data (the ARCHITECTURE gate for R: 'reachable from mobile data; ACL negative test'): the allow list works; everything in the closed list is refused. Testing from inside the container isolates the router layer; testing from the laptop adds the tailnet policy layer. A second tailnet device that the policy does not name, and an unsigned node, reach nothing.
- Re-run the existing `just test-fences` unchanged afterwards; its expectations must still hold. Run it with the Tailscale client off on the laptop, otherwise the 'from WSL' probes may travel through the tailnet.

Source: scripts/tests/backup-fences.sh:1-201; scripts/tests/render-templates.py:1-6,59; justfile:1-4,127-129; docs/phases/phase-2.md:23-48; docs/phases/phase-3.md:62-77; docs/phases/phase-4.md:24-52; docs/ARCHITECTURE.md:785

**6 Conventions** (`repository`)

Files: docs/phases/phase-r-plan.md (plan) and docs/phases/phase-r.md (gate record).

Plan structure (phase-2-plan, phase-3-plan, phase-4-plan): title '# Phase N plan: <topic>'; a 'Status:' line in bold (approved by whom and when; after execution: 'executed on ...; the outcome is in phase-N.md. This file is kept as the plan that was approved'); a Goal paragraph; 'Owner decisions for this phase' or 'Before the window' (Needed from the owner | Why); 'What the household/owner will notice' (Step | Effect); 'Steps' table (# | Step | Changes a device | Gate), numbered N.0, N.1, ..., with N.0 = fresh encrypted backups; a 'How ... is cut over' section where a step needs a procedure; 'Tests' (From | Must work | Must be refused); 'Rollback' (Situation | Action); 'Secrets created in this phase' (Secret | Where); 'Still needed from the owner'.

Gate record structure (phase-2, phase-3, phase-4): '# Phase N gate record: <topic>'; Status; 'What was changed' or 'Plan against result' (Step | Result | Evidence); test tables (From | Test | Expected | Result); 'Deviations from the plan and the design' (Planned | Done | Reason); 'Defect(s) found'; 'Gate items' (G1.. | Who | Closes when); 'Open' / 'Open, not gating'; 'How to operate what this phase built'. ARCHITECTURE section 16: no phase starts until the previous gate is recorded; row R reads 'section 6 conditions; reachable from mobile data; ACL negative test'.

Numbering: exceptions E1-E14 are used, next E15 (ARCHITECTURE section 6 list, router template names, docs/components/openwrt.md table, and the hypervisor table in proxmox.md all carry the same IDs). Security exceptions X1-X26 are used (with X3a, X3b, X8b), next X27 (ARCHITECTURE section 15 table). Backlog B1-B34 are used (B18 was never assigned), next B35 (docs/backlog.md: # | Item | Detail | Owner | When). Decision log: 1-43 used, next 44 (section 19). ADRs: only 0001 exists; its follow-up table reserves 0002-0006 and names 0005 'Administrative access: pinned workstation, optional remote access', never written; Phase R is where it belongs.

Where things go: a new component document at docs/components/<name>.md with the ten headings (purpose, architecture, dependencies, deployment, configuration, security considerations, backup, restore, troubleshooting, removal); a restore runbook as docs/runbooks/restore-<name>.md; new secrets as rows in docs/security/secrets-register.md (section 7 'External accounts', plus a numbered procedure, next R10) with ciphertext only in private/. Text that must be updated with the change: ARCHITECTURE sections 1 (third-party table), 3 (bridge-vids, token grant), 4 (budget line), 6 (VLAN table, port table lan1, matrix row and column, E list, Administration paragraph), 15, 16, 19; docs/components/openwrt.md ('five networks', 'Six firewall zones', 'E1 to E14', the exception table, the access-point sentence); docs/components/proxmox.md (bridge description, firewall table, token grant sentence); SECURITY.md line 49 ('E1 to E14'); DISASTER-RECOVERY.md; backlog B20 (its trigger is 'when remote access is designed').

Process: branch -> pull request -> CI -> merge -> apply from the workstation with a session open; identifiers, backups and secrets go to the private repository; the public-tree policy (policy/public-tree.sh) fails on MAC addresses, e-mail addresses and ciphertext, so tailnet names that contain an e-mail address must stay private.

Source: docs/phases/phase-2-plan.md; phase-3-plan.md; phase-4-plan.md; phase-2.md; phase-3.md; phase-4.md; docs/backlog.md:5-39; docs/ARCHITECTURE.md:343-372,676,703-732,749,785,862-906; docs/adr/0001-platform-stack.md:129-137; docs/security/secrets-register.md (headings); policy/public-tree.sh:52-78

**7 Contradictions and undefined points in the design text** (`repository`)

1. Router address in VLAN 30: the table says '-' (line 317); one is required (10.0.30.1).
2. Subnet-router address: not defined anywhere. The plan must pick one static address; every rule on the router, the hypervisor and the access points names it.
3. 'Tailnet lock, device approval' (line 389): Tailscale states the two are mutually exclusive. The text must drop one.
4. 'ACLs limited to the E1-E3 targets': E1's target is 'router input', with no address. From the remote zone it should be 10.0.30.1, pinned with dest_ip. The usual address 192.168.1.53 should not be advertised into the tailnet: 192.168.1.0/24 is a common hotel and home range, and the design chose 10.0.x for new segments for exactly that reason (line 325). Consequence: `just luci` (default host 192.168.1.53), backup-fences.sh (ROUTER=192.168.1.53) and the inventory's router address are home-only; remote use needs an override and a known-hosts entry for the second address.
5. Remote -> trusted LAN: nothing in E1-E3 lives there except the router's own SSH, which is input, not forwarding. The matrix should say remote -> trusted: deny, no exception. The workstation's home addresses are not a target.
6. E2 includes ping of the management network and E3 includes the admin listener and APIs that do not exist yet; the plan must say whether the remote zone gets ping and whether the servers rows are written now.
7. Source address: a Tailscale subnet router by default rewrites the source to its own address, so every tailnet device looks like one 10.0.30.x host to the lab firewalls. That satisfies 'never source-NATed into VLAN 10 or to the workstation's address', but it means per-device control exists only in the tailnet policy. Worth an X row.
8. The firewall matrix has no remote row or column, and the lan1 port row says 'PVID 10 untagged, 50 tagged'.
9. Section 3 says the token's network grant is 'the single path' for VLAN 50 and calls it the fourth control for guest tags; a second path changes that sentence. The pool is named for Talos VMs.
10. Phase order: the three guest-tag controls, the OpenTofu VM module and the bpg/proxmox provider all arrive in Phase 5; versions.tf has no provider yet. If the container is created with OpenTofu before Phase 5, it is the first real state: backlog B29 (state passphrase rotation, due 'before the first real state') and B31 (negative tests of the token) are pulled forward. The standing instruction that Phase 5 work waits for explicit approval makes this a point to state plainly in the plan.
11. Memory: the text says the container 'would cost 0.125 GiB and leave 1.575 GiB' from planning figures; with the measured host (1891 MiB) and the 8.5 GiB worker the headroom is about 1.8 GiB before and about 1.67 GiB after, above the 1.5 GiB gate.
12. Rule 3 ('day-to-day operation depends on nothing outside the house') and decision 9 stay true only if Tailscale is listed as a new third party for remote work alone, with its failure effect; GitHub becomes its identity provider.
13. Names: ARCHITECTURE describes `list address` entries for `<zone>`, `admin.<zone>` and `pve1.<zone>` on the router, but dhcp.j2 contains none today. Remote work by name is undefined; every recipe uses addresses.
14. At home with the Tailscale client on, the laptop may send admin traffic through the tailnet (a host route beats the default route), so it arrives as 10.0.30.x instead of .196/.197. Undefined; affects tests that depend on the source.
15. Definition of done for the container: monitoring, backup and rebuild are undefined. Its node key is state; under tailnet lock a rebuilt node needs signing by a trusted device, which is a new manual step for DISASTER-RECOVERY.md.
16. Guest firewall: the role manages cluster.fw and host.fw only; whether the container's NIC uses pve-firewall (a <vmid>.fw file) is undefined.
17. ADR 0005 and backlog B20 (WireGuard on the router as the 'natural base for remote access') are open and must be closed or answered by the Phase R decision.

Source: docs/ARCHITECTURE.md:32-45,130,133,184,317,325,334,343-352,389,749-785,872; infrastructure/opentofu/roots/pve/versions.tf; roles/openwrt_config/templates/router-m30/dhcp.j2; justfile:131-133; scripts/tests/backup-fences.sh:22; docs/backlog.md:24,34,36; https://tailscale.com/kb/1226/tailnet-lock; https://tailscale.com/kb/1019/subnets (default source NAT), both read today

## Creating the guest on Proxmox VE

### Recommendation

Build the guest as an unprivileged LXC with Tailscale in userspace networking mode, created by OpenTofu with the existing terraform@pve!tofu token.

Why this one: it is the only container form the token can create. PVE refuses device passthrough and every feature flag except nesting to anything but a root@pam login, and raw lxc.* lines are not in the API at all. Userspace mode needs none of that, and its one hard property (targets always see the container's own 10.0.30.x address) is exactly what the design asks for. All Phase R targets are TCP.

Shape of the guest:
- proxmox_virtual_environment_container, bpg/proxmox pinned to 0.116.x (0.116.0, 2026-10-06).
- unprivileged = true set explicitly (the provider default is false).
- features { nesting = true } and no other flag; never change the features block after creation.
- One NIC on vmbr0 with vlan_id = 30, static IPv4 in 10.0.30.0/24, gateway the router.
- Rootfs on local-lvm, start_on_boot = true, swap 0, protection = true.
- Its own pool (not 'talos').
- Memory limit: start at 256 MiB and lower it after measuring. It is a ceiling, not a reservation, so only real use counts against the 16 GB.

Changes outside OpenTofu, all in the existing hypervisor role:
- A second pool and its ACL row for the token.
- One ACL row on /sdn/zones/localnetwork/vmbr0/30, with the 'pve_guest_vlans | first' expression replaced by one row per VLAN.
- VLAN 30 in bridge-vids.
- A host.fw rule for the container's address.

Template: debian-13-standard_13.6-1_amd64.tar.zst, pinned by name and sha512 in Git. Fetch it with 'pveam download' in the hypervisor role and reference it by ID from OpenTofu. That avoids giving the token Sys.AccessNetwork in this phase; the catch is that the pinned name stops downloading once Proxmox replaces it in the index, so the bump is a documented check. Set ignore_changes on the template ID so a bump never replaces the running guest by surprise.

Fallbacks, in order, if the lab gates fail:
1. Same container with kernel-mode Tailscale: the hypervisor role (already root) runs 'pct set <id> --dev0 /dev/net/tun', and OpenTofu carries ignore_changes = [device_passthrough]. Record it as a documented exception to 'OpenTofu owns guests'. Memory cost unchanged.
2. A small Debian 13 VM, if kernel isolation is judged worth about 0.4 GiB more; the worker shrinks by that amount.
Not recommended: the router package. It is marginal on flash (25.2 MiB payload against 25.6 MB free), lags upstream (1.98.3 against 1.104.1), and puts remote access on the device that enforces segmentation.

Decision for the owner: using OpenTofu here brings forward the provider groundwork that was planned for Phase 5 (provider pin, token plumbing, CI with a provider, tag policy test). No Talos resource is touched. If that is not wanted before Phase 5 is approved, the alternative is to create this one guest with an Ansible role and move it into OpenTofu later.

### Risks

- All three guest forms depend on pve1: when the hypervisor is down, remote access is gone entirely, including to the router and the access points. Only the router package avoids this, at the cost the design rejected.
- Applying a change that replaces or stops the remote-access guest while connected through it cuts the session with no way back until someone is at home. Mitigate with protection = true, ignore_changes on the template ID, and a rule that changes to this guest are applied only from the home network.
- Replacing the container discards Tailscale's node key. Under tailnet lock the new node must be signed again by a trusted device before it works, so a rebuild is not hands-off unless a pre-signed auth key is used.
- The container shares the hypervisor's kernel. It is unprivileged and in userspace mode holds no device and does no forwarding, but a kernel flaw reachable from ordinary system calls would still land on pve1. The VM is the form that removes this.
- Upstream still labels userspace networking 'beta' in the tailscaled flag text, although subnet routing through it is a supported code path.
- Changing the features block later through the token will probably be refused by PVE, because the provider sends explicit zeros on update. Treat features as fixed at creation.
- Moving VLAN 30 into pve_guest_vlans without fixing the 'first' expression would silently drop the token's right on VLAN 50 and break Phase 5 later.
- 128 MiB may be too little for Debian 13 plus tailscaled in userspace mode; an out-of-memory kill inside the container drops remote access without warning unless it is monitored.
- The bridge-vids change runs under the host role's revert timer; a mistake there interrupts pve1's network for up to three minutes.
- Pinned template files eventually disappear from the Proxmox index, and the server offers no trusted HTTPS; integrity depends on the sha512 held in Git.
- bpg/proxmox is 0.x and releases roughly weekly; a minor bump can change container behaviour. Pin the exact minor and review plans on every update.

### Open points

- pve-container version on pve1: I read the master branch (changelog head 6.1.14). Confirm with 'pveversion -v | grep pve-container' that 9.2 as installed carries the same checks; they have existed since device passthrough was introduced, so a difference is unlikely.
- Creation through the token: run 'tofu apply' for the container with unprivileged = true and features { nesting = true }. Expected: success. Then the negative tests: the same NIC without vlan_id, and with vlan_id = 10, must both return 403.
- Features update trap: on a throwaway container, change nesting through the token and see whether PVE answers 'changing feature flags (except nesting) is only allowed for root@pam'. If it does, document 'features are fixed at creation'.
- Does kernel-mode Tailscale need keyctl=1 (only relevant for the fallback)? Test on a throwaway container with dev0 and nesting only: 'tailscale up' and a subnet route must work.
- Userspace subnet router function: from the laptop on mobile data, test SSH to pve1, the web interface on 8006 including the console (websocket), and later 6443 and 50000. On pve1 and the router, confirm the source address seen is the container's 10.0.30.x.
- Memory: after a day of use read 'pct exec <id> -- cat /sys/fs/cgroup/memory.peak' (or memory.current and memory.events for oom_kill) and set the limit from that. No primary source gives tailscaled's footprint.
- Whether the Debian 13 standard template ships python3 and a running sshd (Ansible needs one path in): 'pct exec <id> -- python3 --version' and 'ss -ltn'. This decides between SSH from the workstation into VLAN 30 (a new firewall row) and the pct-based connection plugin community.proxmox.proxmox_pct_remote (new collection, needs paramiko).
- Whether pool membership alone is enough for every call the provider makes on the container (read, update, start, delete): watch for 403 in a full create, change-memory, destroy cycle with the scoped token.
- If OpenTofu is to download the template instead of pveam: add Sys.AccessNetwork on /nodes/pve1 and confirm proxmox_download_file works with it alone. bpg's doc names only Sys.Audit + Sys.Modify; the PVE source shows the alternative.
- Template lifetime: check monthly (or in the drift job) that the pinned file name is still listed in aplinfo-pve-9.dat; 'pveam available --section system | grep debian-13'.
- Minimum memory of a Debian 13 cloud-image VM running only tailscaled, and QEMU's overhead on this host: not verified. Measure only if the VM fallback is taken.
- Router package fit and behaviour (only if that form is reconsidered): 'df -h /overlay' before and after 'apk add tailscale' on the M30, tailscaled's memory from /proc/<pid>/status, and how its own netfilter rules sit beside a default-deny fw4 zone.
- The Tailscale and Proxmox documentation pages were read through a summarising fetch; the source code, package indexes and file listings were read raw. Re-read the exact config lines on https://tailscale.com/kb/1130/lxc-unprivileged before quoting them in a runbook.

### Findings

**1 - What Tailscale and Proxmox say an unprivileged LXC needs** (`primary`)

Tailscale's page (last validated 2026-01-09) says an unprivileged LXC lacks /dev/net/tun and gives two ways to provide it. (a) Raw lines in /etc/pve/lxc/<CTID>.conf, labelled for Proxmox 7: 'lxc.cgroup2.devices.allow: c 10:200 rwm' and 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'. (b) 'pct set CTID --dev0 /dev/net/tun' plus 'pct set CTID --features keyctl=1,nesting=1'. It names userspace networking as the alternative that 'avoids the need for any administrative access at all'. Proxmox documents dev[n] and the features flags in pct(1) without saying who may set them; the source decides that (next finding). Proxmox describes keyctl as 'mostly a workaround for systemd-networkd' and needed for Docker, so it is not a Tailscale requirement in itself; whether kernel-mode Tailscale runs without keyctl is not verified. Nesting is a different matter: Proxmox states systemd needs it (pve-container changelog 6.0.14 'fix #6897: document that systemd requires nesting', 6.0.19 'warn that enabling cgroup nesting may be required for systemd'), so a Debian 13 container should have nesting=1 in every variant.

Source: https://tailscale.com/kb/1130/lxc-unprivileged ; https://pve.proxmox.com/pve-docs/pct.1.html ; https://raw.githubusercontent.com/proxmox/pve-container/master/debian/changelog ; pve-container src/PVE/LXC/Config.pm lines 467-487

**1 - Which of these an API token of a non-root user can set (decides whether automation can create the container without root)** (`primary`)

The TUN device cannot be given to a container by any API token. Nesting can. Read in pve-container master (changelog head 6.1.14), src/PVE/LXC.pm, check_ct_modify_config_perm, lines 1678-1779:
- Line 1681: 'return 1 if $authuser eq 'root@pam''. A token's identity is user@realm!token, so even a root@pam token does not pass. bpg's docs and its issue 3134 say the same.
- dev[n] (line 1709): 'configuring device passthrough is only allowed for root@pam'.
- features on an unprivileged container (lines 1713-1758): only nesting may be changed by a non-root caller, and it needs VM.Allocate. Any other flag (keyctl, fuse, mknod, mount) raises 'changing feature flags (except nesting) is only allowed for root@pam'.
- Raw lxc.* keys are not API parameters at all. The create and update endpoints use additionalProperties => 0 with only the keys of confdesc, and lxc.* lines exist only in the config file parser (Config.pm line 1191). They can be written only by root editing /etc/pve/lxc/<id>.conf. bpg's docs confirm: 'the Proxmox API does not support writing lxc[n] parameters', and the provider writes idmap over SSH with sudo.
- Also root-only: hookscript, bind mounts. A privileged container needs Sys.Modify on '/'.
So terraform@pve!tofu can create an unprivileged container with nesting=1 and nothing else special. A TUN device needs root on the hypervisor (pct as root, or a file edit).

Source: https://raw.githubusercontent.com/proxmox/pve-container/master/src/PVE/LXC.pm (lines 1678-1779) ; src/PVE/API2/LXC.pm lines 140-332 ; https://github.com/bpg/terraform-provider-proxmox/issues/3134 ; https://github.com/bpg/terraform-provider-proxmox/issues/1801 (open since 2025-02: 'Enabling /dev/tun for LXC to run Tailscale')

**2 - Is a plain unprivileged container enough with userspace networking, and the trade-off** (`primary`)

Yes. A subnet router works in userspace mode with no TUN device, no IP forwarding and no netfilter rules, so a plain unprivileged container with only nesting=1 is enough. Tailscale's source: tailscaled's --tun flag accepts 'userspace-networking' and labels it '(beta)'; handleSubnetsInNetstack says netstack handles subnet routes when 'the user has explicitly requested it (e.g. --tun=userspace-networking)'; tryEngine sets netstackSubnetRouter := onlyNetstack; netstack.go has ProcessSubnets, forwardTCP, forwardUDP and its own ping handling. It is enabled with --tun=userspace-networking or FLAGS in /etc/default/tailscaled (kb/1112, validated 2025-11-12; that page does not itself mention subnet routers, the source does).
Trade-offs:
- tailscaled ends each connection and opens a new ordinary socket from the container. The source comment says netstack 'must rewrite the source address' and cannot serve --snat-subnet-routes=false. Targets therefore always see the container's own 10.0.30.x address. That matches the design condition (own zone, never an address in VLAN 10 or the workstation's).
- Only TCP, UDP and ping are carried, not arbitrary IP. Every Phase R target is TCP (22, 8006, 6443, 50000, 443).
- Throughput is lower and CPU and memory use higher than kernel mode. Figures are not verified; this is irrelevant for one administrator's sessions but the memory limit must be measured.
- Programs inside the container reach the tailnet only through the SOCKS5/HTTP proxy. Nothing in Phase R needs that.
- The upstream flag text still says 'beta'.

Source: https://raw.githubusercontent.com/tailscale/tailscale/main/cmd/tailscaled/tailscaled.go (lines 216, 826-857, 879-881) ; https://raw.githubusercontent.com/tailscale/tailscale/main/wgengine/netstack/netstack.go (lines 199-208, 1458-1474, 1783, 2095) ; https://tailscale.com/kb/1112/userspace-networking

**3 - bpg/proxmox provider: address, version, PVE 9 support, container resource** (`primary`)

Registry address bpg/proxmox (registry.opentofu.org/bpg/proxmox). Latest release v0.116.0, published 2026-10-06, and present in the OpenTofu registry; v0.115.0 is from 2026-10-02. The repository's research note pinned '~> 0.115'. README: 'compatible with Proxmox VE 9.x (currently 9.2)', 8.x limited, 7.x unsupported; OpenTofu 1.6 or newer; 0.x minors are not guaranteed backward compatible; the container resource is still on SDKv2.
Resource proxmox_virtual_environment_container supports everything the guest needs:
- unprivileged: default is FALSE and it is ForceNew, so it must be set to true explicitly. Left out, creation would need Sys.Modify on '/' and fail.
- features { nesting, keyctl, fuse, mknod, mount }; docs: 'Changing flags (except nesting) is only allowed for root@pam'.
- device_passthrough { path, mode, uid, gid, deny_write }: exists, but PVE refuses it for a token.
- network_interface { name, bridge, vlan_id, firewall, mac_address }.
- initialization { hostname, dns, ip_config.ipv4 { address, gateway }, user_account.keys }.
- start_on_boot (default true), startup order, memory { dedicated (default 512), swap (default 0) }, disk { datastore_id, size } on LVM-thin, pool_id (ForceNew), protection, tags.
- operating_system.template_file_id is ForceNew: changing the template replaces the container.
Template download: proxmox_virtual_environment_download_file is deprecated ('will be removed in v1.0'); use proxmox_download_file with content_type = "vztmpl", url, checksum and checksum_algorithm (sha512 supported).

Source: https://github.com/bpg/terraform-provider-proxmox/releases ; https://raw.githubusercontent.com/bpg/terraform-provider-proxmox/main/README.md ; main/docs/resources/virtual_environment_container.md ; main/docs/resources/download_file.md ; v0.116.0 proxmoxtf/resource/container/container.go lines 1015-1040, 1187-1193 ; docs\research\2026-10-05-platform-research.md line 63

**3 - Privileges and ACL paths the token needs for such a container** (`primary`)

From the PVE source, for an unprivileged container with one tagged NIC:
- Create: VM.Allocate on /vms/{vmid} or on /pool/{pool}. Per option: memory and swap need VM.Config.Memory; cores VM.Config.CPU; rootfs VM.Config.Disk plus Datastore.AllocateSpace on /storage/<rootfs storage>; net0, hostname, nameserver and searchdomain VM.Config.Network; nesting VM.Allocate; everything else (onboot, ostype, description, startup) VM.Config.Options; start at create VM.PowerMgmt.
- Network: SDN.Use on /sdn/zones/localnetwork/vmbr0/30. A NIC with no tag needs the grant on the bridge itself, which the repository deliberately does not give.
- Template use: Datastore.Audit or Datastore.AllocateSpace on /storage/local.
- Read: VM.Audit. Start and stop: VM.PowerMgmt. Config change: any VM.Config.*. Delete: VM.Allocate on /vms/{vmid}. Pool ACLs are inherited by pool members (pveum docs), so one grant on the pool covers all of these.
- Template download through the API (download-url and query-url-metadata): Datastore.AllocateTemplate on /storage/local AND either Sys.Audit + Sys.Modify on '/' or Sys.AccessNetwork on /nodes/pve1. bpg's doc mentions only the first alternative; the source shows the second.
Against the repository: role TerraformProvisioner already holds every VM.*, Datastore.*, SDN.Use and Pool.* privilege listed. Missing are (1) a pool for this guest with an ACL row, since the only pool ACL is /pool/talos and the host role creates one pool; (2) an ACL row on /sdn/zones/localnetwork/vmbr0/30; (3) Sys.AccessNetwork, only if OpenTofu downloads the template. The storage and node rows already exist.

Source: pve-container src/PVE/LXC.pm 1678-1779, src/PVE/API2/LXC.pm 145-151, 298-332, 817-819, src/PVE/API2/LXC/Status.pm 126-128, src/PVE/API2/LXC/Config.pm 103-119 ; pve-guest-common src/PVE/GuestHelpers.pm 397-421 ; pve-storage src/PVE/Storage.pm 619-656 and src/PVE/API2/Storage/Status.pm 738-757 ; pve-manager PVE/API2/Nodes.pm 1894-1905 ; https://pve.proxmox.com/pve-docs/chapter-pveum.html ; infrastructure\ansible\playbooks\group_vars\proxmox.yaml lines 43-97

**3 - Known problems with the provider on PVE 9 that touch this guest** (`primary`)

No open issue was found that blocks a plain unprivileged container on PVE 9.2. Relevant items:
- Issue 1801 (open): no way to set the raw TUN lines. Issue 3134 (open, 2026-10-05): root@pam-only operations fail for tokens; the only current workaround is the root password.
- Out-of-band dev0 causes drift: the provider's read puts any dev[n] it finds into state (container.go lines 3068-3077). If Ansible added dev0, every plan would try to remove it and get a 403, unless lifecycle.ignore_changes = [device_passthrough] is set.
- Possible trap on feature updates: on create the provider sends only flags that are true ('features=nesting=1'), which PVE accepts with VM.Allocate. On update it sends all flags including explicit zeros (containerGetFeaturesForUpdate). PVE's comparison treats an absent flag and '0' as different, so a later change of the features block through a token would probably be refused. This is my reading of the two sources, not tested.
- README known issues: lock errors when several guests are created in parallel (parallelism=1 helps). Does not matter for one container.
- ip_config blocks are matched to NICs by position (issue 377 open). Does not matter with one NIC.

Source: https://github.com/bpg/terraform-provider-proxmox/issues/1801 ; /issues/3134 ; /issues/377 ; v0.116.0 proxmoxtf/resource/container/container.go lines 2565-2628, 3068-3077, 3786-3794 ; main/README.md 'Known Issues'

**4 - Creating the container with Ansible on the hypervisor instead, and whether this guest is a good first use of the provider** (`repository`)

Ansible alternative: a role on pve1 running 'pct create' and 'pct set', made idempotent by checking /etc/pve/lxc/<id>.conf and comparing 'pct config'. It runs as root through the existing ops + sudo path, and the pct CLI acts as root@pam, so every option is allowed including dev0. It needs no new token privilege, but the creator is full root on the hypervisor. The API module community.proxmox.proxmox (collection 2.1.0, not in the repository's requirements.yml; community.general 13.5.0 as vendored has no proxmox modules) goes through the same API and hits the same root@pam limits.
Comparison: OpenTofu keeps the project rule, uses a scoped token that cannot touch the host, records the guest in state, and shows a plan before change. Ansible/pct is the only non-root-password way to get a TUN device, but it makes the hypervisor role own a guest, has no plan step, and deletion must be hand-written.
Good first use of the provider? Yes, if the container is the plain userspace one. It exercises the provider pin, token plumbing, pool and per-VLAN ACL scoping, checksum-verified download and the 'no NIC without a tag' guard on a guest that is cheap to destroy, before the Talos VMs depend on them. The coupling to manage: versions.tf has no required_providers yet, and the provider setup, CI validation with a provider, Renovate rule and VLAN-tag policy test were planned for Phase 5, which the owner has not approved. Phase R would have to bring forward only that groundwork and no Talos resource. Keep it apart: its own pool, its own .tf file or root, and protection against accidental replacement.
It is a bad first use if the TUN variant is chosen, because then OpenTofu cannot own the whole guest.

Source: infrastructure\ansible\requirements.yml ; infrastructure\opentofu\roots\pve\versions.tf and main.tf ; https://galaxy.ansible.com/ui/repo/published/community/proxmox/ ; https://github.com/ansible-collections/community.proxmox/tree/main/plugins

**5 - Debian 13 container template: location, exact name, checksum, pinning, updates** (`primary`)

Published at http://download.proxmox.com/images/system/. Current amd64 file: debian-13-standard_13.6-1_amd64.tar.zst, dated 2026-07-14, 129,954,319 bytes. An older debian-13-standard_13.1-2_amd64.tar.zst (2025-10-01) is still on the server but no longer in the index.
Checksum source: the appliance index http://download.proxmox.com/images/aplinfo-pve-9.dat with detached signature aplinfo-pve-9.dat.asc. Its entry gives sha512sum 4c0c27ca6ceab5ef0b84db57825a00f26157ef1854bafe97297813e1cbe8ecb8cc9c453cab6b3b0efe1ba193a50c47ece1e41d950e411b8730b835b71e9e754b (md5 a6148ff6f0d60e643a6e5f33497cecea). The same values are in the per-file debian-13-standard_13.6-1_amd64.aplinfo.
How PVE verifies: 'pveam update' checks the index signature with sqv against /usr/share/doc/pve-manager/trustedkeys.gpg (PVE/APLInfo.pm lines 172-178); 'pveam download' requires the sha512 from that index (hash_required => 1). The index refreshes daily through the pve-daily-update timer.
HTTPS is not usable on that host: a TLS request to download.proxmox.com failed certificate validation from here, and PVE itself uses plain http plus the signature. Integrity therefore rests on the pinned sha512.
Pinning, two ways:
(a) proxmox_download_file with the http URL, checksum and checksum_algorithm = "sha512" in Git. Needs Sys.AccessNetwork on the node for the token.
(b) 'pveam download local <file>' in the hypervisor role, with OpenTofu referring to local:vztmpl/<file>. Needs no new token privilege and uses Proxmox's signed index, but pveam only serves names still in the index, so a pinned old name fails once Proxmox publishes a newer build.
Updates: the template is only the seed; patching inside the container is apt with unattended upgrades. A template bump is a Git change of name and sha512. Because template_file_id is ForceNew, a bump replaces the container unless ignore_changes is set on it and replacement is done deliberately. No Renovate datasource exists for this index, so the bump is a documented manual check.

Source: http://download.proxmox.com/images/system/ ; http://download.proxmox.com/images/aplinfo-pve-9.dat ; https://raw.githubusercontent.com/proxmox/pve-manager/master/PVE/APLInfo.pm (lines 172-178, 202-204) ; pve-manager PVE/API2/Nodes.pm lines 1773-1845 ; https://pve.proxmox.com/pve-docs/chapter-pct.html

**6 - A small VM instead (Debian 13 cloud image with cloud-init)** (`primary`)

Image: https://cloud.debian.org/images/cloud/trixie/20261001-2618/ (latest build 2026-10-01), debian-13-genericcloud-amd64.qcow2, 326 MB, with a SHA512SUMS file in the same directory.
Minimum memory: Debian's guide gives 512 MB as the minimum for a system without desktop (table 3.2; 'as little as 350MB' with swap, for the installer). No Debian or Tailscale document states a lower figure for the cloud image, so 384 MiB or less is not verified. Under the repository's rules (no ballooning, no overcommit) the whole assignment counts, plus the QEMU process overhead (size not verified). Realistic cost: about 0.5 to 0.6 GiB, against 0.125 GiB planned for the container, so roughly four times as much. Headroom would fall from about 1.8 GiB to about 1.2 GiB, or the worker shrinks by the difference, as ARCHITECTURE.md section 8 requires.
Gained: its own kernel, so a kernel-level escape from the remote-access endpoint does not land on the hypervisor; a native TUN device with kernel-mode routing; no root@pam question; the same provider resources and image-download path the Talos VMs will use.
Lost: memory; a second kernel to patch and reboot; slower rebuild. Custom cloud-init user-data would need snippet upload over SSH, which the design avoids, so configuration stays with PVE's built-in cloud-init fields plus Ansible.

Source: https://cloud.debian.org/images/cloud/trixie/latest/ ; https://www.debian.org/releases/trixie/amd64/ch03s04.en.html ; docs\ARCHITECTURE.md line 184

**6 - Memory of the container variants (128 MiB target)** (`not-verified`)

A container's memory value is a cgroup limit, not a reservation: only what is used counts against the host. PVE's default is 512 MiB with 512 MiB swap and a minimum of 16; bpg's defaults are 512 dedicated and 0 swap. Whether Debian 13 with systemd plus tailscaled stays under 128 MiB is not verified from any primary source, and userspace mode uses more than kernel mode. The Debian package itself is large on disk: tailscale 1.104.1 for trixie has Installed-Size 75,966 KiB and depends on iptables.

Source: https://pve.proxmox.com/pve-docs/chapter-pct.html ; https://pkgs.tailscale.com/stable/debian/dists/trixie/main/binary-amd64/Packages ; bpg docs/resources/virtual_environment_container.md

**7 - Tailscale package on the OpenWrt router instead** (`primary`)

Package name 'tailscale' in the OpenWrt packages feed. On 25.12.2 and 25.12.5 for aarch64_cortex-a53 the version is 1.98.3-r1; upstream stable is 1.104.1 (2026-10-07). The version is tied to the OpenWrt feed, and the OpenWrt wiki itself warns the package 'may be outdated and missing security updates'. Dependencies: ca-bundle and kmod-tun.
Size: the .apk is 9,908,301 bytes; I decompressed it and its payload is 26,389,296 bytes (25.2 MiB), essentially the one tailscaled binary. The 24.10 index lists Installed-Size 23,275,520 for 1.80.3, which is consistent. The repository measured 25.6 MB free on the M30's overlay, not 50 MiB. UBIFS compresses, so it may fit, but with little room and an upgrade may need old and new side by side for a moment (not verified). Treat it as marginal.
Memory use on the router: not verified. The repository measured 360 MB free RAM there, so RAM is not the constraint.
How VLAN 30 would be modelled: there would be no VLAN. 'remote' becomes a fw4 zone bound to the unmanaged device tailscale0. The wiki's recipe (zone input ACCEPT, masquerading on, forward to LAN) is the opposite of this design: with masquerading, forwarded traffic takes the router's own address in the target VLAN, e.g. 10.0.10.1, which the design forbids. It would need --snat-subnet-routes=false, zone input and forward REJECT, and numbered rules matching 100.64.0.0/10 sources. The wiki says --netfilter-mode=off is not needed from 23.05 on, which means Tailscale installs its own netfilter rules next to fw4; how those interact with a default-deny zone is not verified.
Security trade-off: the device that enforces every zone boundary would also run the internet-facing, third-party-controlled agent as root. A flaw there gives control of the segmentation itself rather than a foothold in one small zone. It also adds a large Go daemon and a lagging version to the one device that must stay simple. In its favour: no hypervisor privilege, no host memory, and it keeps working when pve1 is down.

Source: https://downloads.openwrt.org/releases/25.12.5/packages/aarch64_cortex-a53/packages/ (index.json and tailscale-1.98.3-r1.apk) ; https://raw.githubusercontent.com/openwrt/packages/openwrt-25.12/net/tailscale/Makefile ; https://openwrt.org/docs/guide-user/services/vpn/tailscale/start (secondary, community wiki) ; docs\INITIAL-ASSESSMENT.md line 62

**8 - Ranking of the four forms** (`primary`)

1 = best.
Privilege needed to create:
1. LXC with userspace networking: the existing scoped token plus two new ACL rows.
2. Small VM: same token and rows, plus an image download path.
3. Router package: nothing on the hypervisor, but root on the enforcement device through the existing router role.
4. LXC with TUN: root@pam on the hypervisor, no token can do it.
Attack surface:
1. Small VM (own kernel).
2. LXC userspace (shared kernel, but no device, no forwarding, no netfilter, only proxied TCP/UDP).
3. LXC with TUN (shared kernel, device node, forwarding and netfilter inside the container).
4. Router package (the segmentation enforcer terminates remote access).
Host memory:
1. Router package (none on pve1).
2. LXC with TUN (about 0.125 GiB planned).
3. LXC userspace (somewhat more, not measured).
4. Small VM (about 0.5 to 0.6 GiB).
Reproducibility from Git:
1. LXC userspace (OpenTofu creates, Ansible configures, upstream apt repository gives an exact Tailscale version).
2. Small VM (same, more parts).
3. LXC with TUN (a root-only step outside OpenTofu, or split ownership with ignore_changes).
4. Router package (version fixed by the OpenWrt feed, marginal flash, node state on the overlay).
When the hypervisor is down:
- Router package: remote access to the router and both access points survives.
- All three guests: remote access is gone entirely, including to the router and access points. This is the one criterion where the preferred form is worst, and it is shared by every form that honours 'not on the router'.

Source: synthesis of the findings above

**Repository facts the plan must account for** (`repository`)

- Adding VLAN 30 to pve_guest_vlans has a side effect: the token's SDN ACL path is built with 'pve_guest_vlans | first' (group_vars/proxmox.yaml line 95). A list of [30, 50] would silently move the grant from VLAN 50 to VLAN 30. The ACL needs one row per VLAN.
- bridge-vids on vmbr0 is rendered from the same list (interfaces.j2 line 19, currently '50'). VLAN 30 must be added there, under the role's 180-second revert timer, and the router's lan1 trunk must carry VLAN 30 tagged.
- The host role creates exactly one pool (pve_pool: talos). A second pool for this guest needs a role change.
- TerraformProvisioner has no Sys.AccessNetwork; the repository already planned to add it on the node 'with a test' when a download needs it.
- pve1's own firewall admits SSH and 8006 only from the workstation's two addresses and drops the rest; a host.fw rule for the container's 10.0.30.x address is needed next to the router rule.
- The container sits on vmbr0 with tag 30 while the host address is untagged in VLAN 10, so traffic from the container to pve1 goes out to the router and back. The router does enforce it.
- versions.tf declares no provider yet; ARCHITECTURE.md budgets 0.125 GiB for this guest, leaving 1.575 GiB by its own arithmetic.

Source: infrastructure\ansible\playbooks\group_vars\proxmox.yaml lines 26, 38-49, 79-97 ; infrastructure\ansible\roles\pve_host\templates\interfaces.j2 line 19 ; infrastructure\ansible\roles\pve_host\tasks\firewall.yaml lines 26-41 ; infrastructure\opentofu\roots\pve\versions.tf ; docs\ARCHITECTURE.md lines 130, 133, 184

