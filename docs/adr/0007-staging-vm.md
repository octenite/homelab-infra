# ADR-0007: A staging VM for an outside team, in its own network, reached through a tunnel it dials out

- Status: Accepted. The owner approved the plan on 2026-11-14
- Date: 2026-11-14
- Deciders: repository owner
- Supersedes: none. It uses VLAN 40, which `../ARCHITECTURE.md` section 6 reserved, and takes memory that section 4 planned for the cluster's worker (see "Consequences")

## Context

On 2026-11-12 the owner asked for a server for a development team of five to ten people, needed within three days: a staging environment for a web application backend that the team deploys to and tests as if it were production. Production itself runs on rented cloud servers; this is not it. What the owner asked for:

- a general-purpose Linux VM that behaves like a rented cloud instance, running containers with Docker; not tied to one application;
- 2 vCPU, 4 GiB of memory, 30 GB of disk to start;
- the team needs the web sites, SSH, and deploys from GitHub Actions; everyone is in one GitHub organisation; the repositories are private;
- the sites live under a domain in the company's own Cloudflare account, not the owner's;
- the data is test data: it may look real, but it is no customer's.

This is the first time people outside the household use something in this lab, and the first VM on the hypervisor. It follows the owner's direction of 2026-10-09: applications first, the platform as it is needed.

Facts that bound the choice:

- Both ends of the home connection sit behind the provider's NAT. Nothing at home can listen on the internet.
- Whoever may deploy to the VM may run anything on it, as root in practice (membership of the Docker group is root). The VM must be treated as a machine the lab does not control.
- The hypervisor has 16 GB of memory, no UPS and one disk, and a home internet line.
- The cluster of Phase 5 is not built, so its memory is free today.
- This repository is public; the company's name and domain are not the owner's to publish.

## Decision

1. **One Debian VM, `stg1`,** guest 4010, created by OpenTofu from a pinned Debian cloud image, configured by Ansible: Docker, a deploy account, the GitHub Actions runner, the tunnel client. 2 vCPU, 4 GiB, 30 GB. The applications on it are the team's: they bring their compose files and deploy as they would on a rented server.
2. **Its own network: VLAN 40, zone `dmz`, 10.0.40.0/24.** The VM may reach the router's resolver and clock, and the internet on the ports a general-purpose server needs (E23). No rule leads from the zone to any network at home. Only the workstation's SSH leads in (E24). The same is enforced a second time by the hypervisor's own filter on the VM's network device, which nobody inside the VM can change.
3. **The team reaches it through one Cloudflare Tunnel** that the VM dials out, on the company's Cloudflare account: HTTPS hostnames for the sites, and one hostname for SSH behind Cloudflare Access with the company's GitHub organisation as the login. Nothing at home is opened.
4. **Deploys by a self-hosted GitHub Actions runner on the VM,** registered to the company's organisation or repositories. It connects outwards and takes jobs; no deploy key from outside reaches in.
5. **A nightly backup of the VM** to the existing backup server, in the nightly window.
6. **The company's name, domain and repositories stay out of this repository.** They are in the private inventory; this tree says "the company".
7. **The tunnel and the Access rules are made in the company's Cloudflare dashboard, by hand, for now.** Managing them from Git needs an API token of an account that is not the owner's, and more time than the deadline leaves (backlog B59).

## Alternatives considered

| Alternative | Why not |
|---|---|
| A rented cloud server | The honest better choice for uptime, and the fallback if the home line or the single host proves too unreliable. The owner chose home for now: it costs nothing, and staging can tolerate outages |
| The VM in the servers network (VLAN 50) | That network is the cluster's, with rules written for it. A machine that outsiders control needs a zone with no rule into anything |
| A container instead of a VM | Docker inside an unprivileged container needs features only the hypervisor's root login may set, and the guest would share the hypervisor's kernel while running code the lab does not control |
| Access with Tailscale, like the administration path | The free plan is for personal use and its user count is small; every developer would need the client and a place in the owner's tailnet, next to the lab's own devices |
| Opening a port on the router | Impossible behind the provider's NAT, and not wanted |
| Cloudflare's login page in front of the sites | It would block the application's own API clients and incoming webhooks. It guards SSH only; the sites keep their own login |
| The applications inside the future cluster | Nothing the team can use this week, and they asked for something that behaves like their production servers |

## Consequences

- **Memory.** 4 GiB of the hypervisor's 16 go to this VM, fixed. Section 4 planned 8.5 GiB for the cluster's worker; when Phase 5 is planned, the budget is re-based with this VM in it: a smaller cluster, a smaller staging VM, or more memory in the host.
- **Uptime is the home's.** One host, no UPS, one line. The team is told so.
- **A new kind of trust.** The VM is assumed hostile in the design of its network. What stands between it and the home is the router's zone and the hypervisor's filter, tested from inside the VM before the team gets access (`just test-staging`).
- **New exceptions:** E23 and E24 in section 6; X36 (people outside the household log in to a machine at home, through a third party's tunnel and login), X37 (the tunnel and its access rules are not in Git). They enter section 15 with the step that builds each.
- **A third outside dependency for this VM only:** the company's Cloudflare account and GitHub organisation decide who gets in. The owner does not control the second.
- **The backup server holds its first VM image.** The datastore has room (128 GiB); the nightly window gets longer.
- **Removal:** destroy the VM with OpenTofu, delete the tunnel in the dashboard, revert the pull requests of the network. Nothing else depends on it.
