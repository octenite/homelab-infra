# Component: remote1, the administration container

Status: created in Phase R step R.7 (2026-10-12); its configuration and the tunnel are step R.8, in progress. This document is written with R.8 and completed with its gate record.

## Purpose

The home end of the administration path (`docs/adr/0005-administrative-access.md`): a container on the hypervisor that carries the laptop's traffic, through Tailscale, to the hypervisor's SSH and web interface, and nothing else. It runs only while the laptop travels (decision D12). It holds no data and no secret worth keeping (decision D9): it is rebuilt, not restored.

## Architecture

- An unprivileged Debian 13 container, guest 3010, pool `remote`, on the hypervisor's bridge in VLAN 30 with the one address 10.0.30.10/24; 1 core, a 256 MiB limit, 4 GiB thin disk. Created by OpenTofu through the module `pve-lxc` (`infrastructure/opentofu/roots/remote`), which refuses any other pool or VLAN. No nesting feature: the template runs cleanly once three tmpfs mount units are masked.
- Configured by the Ansible role `remote_ct` (`just remote-apply`), after a one-time `just remote-bootstrap` that creates the operator account and closes root's SSH login.
- Tailscale, Linux build pinned by version, runs as the unprivileged user `tailscaled` in userspace-networking mode: no TUN device, no capability, no rule of its own in the kernel, no forwarding. It advertises the one route 10.0.10.10/32 and carries the tag `tag:remote-admin`. A connection from the laptop to the hypervisor is terminated by the daemon and dialled anew from the container's own address, so the hypervisor and the router see 10.0.30.10.
- Four layers stand between the internet and the house, from the inside out:

| Layer | Sees | Written by | Holds against |
|---|---|---|---|
| The container's own filter (nftables, `/etc/nftables.conf`) | addresses, ports, and which user sends | the role | a compromised tunnel process: it may reach the hypervisor's two ports and the internet on 443, nothing else, and nothing on loopback |
| The hypervisor's filter on the container's network device (`/etc/pve/firewall/3010.fw`) | addresses, ports, frame types, the sending address | the hypervisor play | a compromised container: one address, one MAC, no tagged frames, the same two destinations |
| The router's zone `remote` (E15 to E17) | addresses and ports | the router play | both of the above, and a stolen OpenTofu token (exception X33) |
| The hypervisor's own logins | key-only SSH; password and second factor on the web interface | the hypervisor play | whoever gets this far |

The Tailscale policy (`infrastructure/opentofu/roots/tailscale/policy.hujson`) is the fifth, on the other side: only the laptop's address may use the tag, and only towards the two ports.

Users inside: `root` (no SSH path; `pct enter` on the hypervisor), `ops` (the operator account, key-only SSH from the workstation's two addresses, sudo), `tailscaled` (the daemon), `health` (the dead-man's switch timer), `_apt` (package fetches). The filter lets `tailscaled`, `_apt`, `health` and `root` reach the internet on tcp 443, name lookups at the router for everyone, and the hypervisor's ports 22 and 8006 for `tailscaled` only.

## Dependencies

- The hypervisor with VLAN 30 on its bridge and the firewall file for guest 3010 (step R.6, R.7).
- The router's zone `remote` (step R.5).
- The tailnet with node signing on and the laptop as signer (steps R.2 to R.4); the policy with the tag's owner and the route's approval (R.8).
- The owner at a browser for the one login, and at the laptop for the one signature.

## Deployment

In this order, at home, with a session open (`docs/runbooks/rebuild-remote1.md` has the same steps with their checks):

| Step | Command | What it does |
|---|---|---|
| 1 | `just pve-apply`, `just tofu remote apply` | the hypervisor's firewall file, then the container, stopped |
| 2 | `just remote-start` | reads the container back, starts it, reads it again |
| 3 | `just remote-bootstrap` | as root, once: HTTPS package sources, `sudo`, the operator account, root's SSH login closed |
| 4 | `just remote-apply` | the role: packages and the pinned Tailscale, masked units, kernel settings, SSH, the filter, the daemon as its own user, the health timer |
| 5 | `just tofu tailscale apply` | the tag's owner and the route's approval in the policy (once; already in Git) |
| 6 | `just remote-login` | the owner's login at a browser; the container is a member but locked out |
| 7 | on the laptop, connected | `tailscale lock sign nodekey:... tlpub:...` as the script printed it |
| 8 | `just secret-set ... remote_ct_health_ping_url`, then `just remote-apply`, `just test-remote layers`, `just pve-apply`, `just test-remote` | the switch's address stored; the preferences set once and read back, the health timer installed; the probes with each layer off in turn; the hypervisor's file restored; the final read-back. A further `just remote-apply` must change nothing |
| 9 | `ssh ops@10.0.10.10 sudo pct reboot 3010`, then `just test-remote` | one boot observed: the filter, the masked units, the sysctls and the SSH listener come back by themselves |
| 10 | `ssh ops@10.0.10.10 sudo pct stop 3010`; the check paused in the console | the container runs only while the laptop travels (decision D12) |

A rebuild starts with section 3 of the runbook: the old device removed in the console, the guest deleted on the hypervisor, the state entry removed.

## Configuration

| What | Where |
|---|---|
| Guest id, address, size, template pin | `infrastructure/opentofu/roots/remote/main.tf`, `template.auto.tfvars.json` |
| The hypervisor's filter for the guest | `infrastructure/ansible/roles/pve_host/templates/guest-remote-admin.fw.j2` |
| Everything inside: addresses, sources, the Tailscale version and key checksum, the tag, the route, the health interval | `infrastructure/ansible/playbooks/group_vars/remote.yaml` |
| The dead-man's switch address | `private/ansible/inventory/host_vars/remote1/secrets.sops.yaml`, key `remote_ct_health_ping_url`; stored after the login and the signature, since the timer reports failure until then and the service alerts on a failure report at once |
| The check at healthchecks.io | created by the owner: period 5 minutes, grace 10 minutes (the timer runs every 5 minutes plus up to 30 s; a run takes up to 30 s). Paused by hand in the console whenever the container is stopped on purpose, until `travel.ps1` (step R.9) does it |
| What the tag may do | `infrastructure/opentofu/roots/tailscale/policy.hujson` |

A new Tailscale version is a pull request on `remote_ct_tailscale_version`; the role lifts the hold, installs that version, holds again. Security updates from Debian apply unattended; the pinned package is outside their scope twice over (origin and blacklist). No automatic reboot: the container is restarted by `travel.ps1 -Home` and `-Away`, so every trip starts with fresh processes; an update of a library a running daemon holds reaches it at the next restart.

## Security considerations

- The tunnel's process is the one that faces the internet. It runs without privileges and under the container's filter, which lets it dial exactly two addresses; the hypervisor's and the router's filters repeat that from outside.
- A connection from the tailnet addressed to the container itself is dialled to loopback by the daemon; the filter drops the daemon's loopback output and sshd listens on 10.0.30.10 only. The policy grants nothing towards the tag in any case.
- The node's key does not expire (tagged devices, exception X27). It lives in `/var/lib/tailscale`, readable by root and the daemon's user; a rebuild gets a new key, and the old device must be removed in the console.
- Root has no SSH path; the two operator keys are the only way in, from the workstation only.
- The container's SSH host key changes with every rebuild; the workstation remembers it under the name `remote1` (`ssh-keygen -R remote1` after a rebuild).

## Backup

None (decision D9). A rebuild from Git takes the owner about ten minutes at home: the runbook, the login, the signature.

## Restore

`docs/runbooks/rebuild-remote1.md`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `just remote-login` says the container is not `NeedsLogin` | It is logged in already; `sudo tailscale status` on the container. A new login is a new device: only after `tailscale logout` and the removal of the old device in the console |
| The container is a member but has no connectivity | Locked out: it needs the laptop's signature (`sudo tailscale lock status` on the container prints the command) |
| The route shows as not approved in the console | It was advertised before the policy held the approval: `sudo tailscale set --advertise-routes=` then `sudo tailscale set --advertise-routes=10.0.10.10/32` |
| `systemctl is-system-running` says degraded | `systemctl --failed`; the three tmpfs mount units are masked by the role, anything else is new |
| The health check reports failure | `journalctl -u remote-health -u tailscaled` in the container; `sudo tailscale status --json` |
| A probe of `just test-remote` says `forbidden` where the design says open | The container's own filter refuses the user that tried: as root only 443 and name lookups are open; the hypervisor's two ports are the tunnel user's |

## Removal

1. Remove the device in the Tailscale console.
2. `docs/runbooks/rebuild-remote1.md`, section 3, steps 2 to 4 (protection off, the guest destroyed, the state entry removed); revert the pull requests of R.7 and R.8.
3. The policy: remove the tag's owner, the route's approval and the grant through the tag.
