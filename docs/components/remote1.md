# Component: remote1, the administration container

Status: created in Phase R step R.7 (2026-10-12); configured, logged in and signed in step R.8 (passed 2026-10-13); started and stopped by travel mode since R.9. Step R.10 rehearses its rebuild and measures its memory; the figures go here with that step's gate record.

## Purpose

The home end of the administration path (`docs/adr/0005-administrative-access.md`): a container on the hypervisor that carries the laptop's traffic, through Tailscale, to the hypervisor's SSH and web interface, and nothing else. It runs only while the laptop travels (decision D12). It holds no data and no secret worth keeping (decision D9): it is rebuilt, not restored.

## Architecture

- An unprivileged Debian 13 container, guest 3010, pool `remote`, on the hypervisor's bridge in VLAN 30 with the one address 10.0.30.10/24; 1 core, a 768 MiB limit (256 MiB was the plan's ceiling; measured on 2026-10-12, the hypervisor killed Ansible's apt module at that limit and a configure run peaked at 509 MiB at 512, so 768 leaves headroom for an unattended rebuild; steady-state use is about 40 MB and the limit reserves nothing), 4 GiB thin disk. Created by OpenTofu through the module `pve-lxc` (`infrastructure/opentofu/roots/remote`), which refuses any other pool or VLAN. No nesting feature: the template runs cleanly once three tmpfs mount units are masked.
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
| 4 | `just remote-apply` | the role: packages and the pinned Tailscale, masked units, kernel settings, SSH, the filter, the daemon as its own user. Not yet the health timer: the role installs it only once the node is logged in and signed |
| 5 | `just tofu tailscale apply` | the tag's owner and the route's approval in the policy (once; already in Git) |
| 6 | `just remote-login` | the owner's login at a browser; the container is a member but locked out |
| 7 | on the laptop, connected | `tailscale lock sign nodekey:... tlpub:...` as the script printed it |
| 8 | `just secret-set ... remote_ct_health_ping_url` (the first build only: a rebuild finds it stored), then `just remote-apply`, `just test-remote layers`, `just pve-apply`, `just test-remote` | the switch's address stored; the preferences set once and read back, the health timer installed; the probes with each layer off in turn; the hypervisor's file restored; the final read-back. A further `just remote-apply` must change nothing |
| 9 | `ssh ops@10.0.10.10 sudo pct reboot 3010`, then `just test-remote` | one boot observed: the filter, the masked units, the sysctls and the SSH listener come back by themselves |
| 10 | `ssh ops@10.0.10.10 sudo pct stop 3010`; the check paused in the console | the container runs only while the laptop travels (decision D12) |

A rebuild starts with section 3 of the runbook: the container stopped and its check paused, then the old device removed in the console, the guest deleted on the hypervisor, the state entry removed. Then the steps above, with `ssh-keygen -R remote1` before step 2 and without the `secret-set` of step 8. After the signature, the new tailnet address goes into `hosts.remote1` of the policy by pull request (runbook, section 2).

## Configuration

| What | Where |
|---|---|
| Guest id, address, size, template pin | `infrastructure/opentofu/roots/remote/main.tf`, `template.auto.tfvars.json` |
| The hypervisor's filter for the guest | `infrastructure/ansible/roles/pve_host/templates/guest-remote-admin.fw.j2` |
| Everything inside: addresses, sources, the Tailscale version and key checksum, the tag, the route, the health interval | `infrastructure/ansible/playbooks/group_vars/remote.yaml` |
| The dead-man's switch address | `private/ansible/inventory/host_vars/remote1/secrets.sops.yaml`, key `remote_ct_health_ping_url`. The timer reports failure until the node is logged in and signed, and the service alerts on a failure report at once (it also resumes a paused check), so the role installs the timer only once `tailscale lock status` says the node is signed: a rebuild, which finds the address stored, does not alert once its check is paused (runbook, section 3; step R.10) |
| The check at healthchecks.io | created by the owner: period 5 minutes, grace 10 minutes (the timer runs every 5 minutes plus up to 30 s; a run takes up to 30 s). Paused by hand in the console whenever the container is stopped on purpose; `travel.ps1 -Home` says so when it stops the container. It stays a hand step: the address stored can report to the check but cannot pause it (`docs/components/travel-mode.md`). The check must keep its default of resuming on the next ping: `travel.ps1 -Away` sends one. It alerts by email and through healthchecks.io's own Telegram integration (its bot `@HealthchecksBot`, linked to the owner's chat in the console, owner's decision of 2026-10-19). That integration holds no secret of the lab: the lab's own bot token stays with pve1 and pbs1 and is not given to healthchecks.io |
| What the tag may do | `infrastructure/opentofu/roots/tailscale/policy.hujson` |

A new Tailscale version is a pull request on `remote_ct_tailscale_version`; the role lifts the hold, installs that version, holds again. Security updates from Debian apply unattended; the pinned package is outside their scope twice over (origin and blacklist). No automatic reboot: the container is stopped by `travel.ps1 -Home` and started by `-Away`, so a trip that follows a `-Home` starts with fresh processes (`-Away` keeps a container that already runs); an update of a library a running daemon holds reaches it at the next restart. Debian's two update timers are persistent: a run they missed while the container was stopped happens soon after the next start, within the timers' random delay, so the first part of a trip may carry the update run and its memory peak.

Memory: `just remote-memory` reads the container's cgroup on pve1: the working set now (memory less the page cache it can give back; a moment's value, not a peak), the peak since this start (page cache included, so an upper bound), the limit, oom kills, and whether unattended-upgrade ran in this start. `sample <seconds>` and `window` record the highest working set over a span. `travel.ps1 -Home` reads it before it stops the container and adds the line to `C:\ProgramData\homelab\remote1-memory.log` once the stop succeeded; the line's `pid=` names the start, and of several lines with one pid only the last counts (drill 5 of the plan, backlog B49).

The working set of an update run, the figure drill 5 decides on, is measured at home with the container running:

1. Terminal 1: `just remote-memory window`.
2. Terminal 2: `ssh ops@10.0.10.10 sudo pct exec 3010 -- systemctl start apt-daily.service apt-daily-upgrade.service`. Both are oneshot units, so the command returns when the run ends.
3. Check that the run really happened: `ssh ops@10.0.10.10 sudo pct exec 3010 -- tail -n 5 /var/log/unattended-upgrades/unattended-upgrades.log` shows an entry from now. Apt's daily script skips unattended-upgrade when it ran the same day; then run `ssh ops@10.0.10.10 sudo pct exec 3010 -- unattended-upgrade -v` in the same window.
4. Press Enter in terminal 1 and record "highest working set" and "memory.peak over the window".

## Security considerations

- The tunnel's process is the one that faces the internet. It runs without privileges and under the container's filter, which lets it dial exactly two addresses; the hypervisor's and the router's filters repeat that from outside.
- A connection from the tailnet addressed to the container itself is dialled to loopback by the daemon; the filter drops the daemon's loopback output and sshd listens on 10.0.30.10 only. The policy grants nothing towards the tag in any case.
- In userspace mode the daemon has no tunnel device, so it serves its peer API on a real socket bound to a random high port on every address (it changes at each start). There is no supported flag to bind it elsewhere, and it does not matter: the container's input chain drops everything but SSH from the workstation, so the port answers to nothing off-box. The test sets this listener aside by owner and reports it on its own; the one listener the design pins is sshd, on the container's address.
- The node's key does not expire (tagged devices, exception X27). It lives in `/var/lib/tailscale`, readable by root and the daemon's user; a rebuild gets a new key, and the old device must be removed in the console.
- Root has no SSH path; the two operator keys are the only way in, from the workstation only.
- The container's SSH host key changes with every rebuild; the workstation remembers it under the name `remote1`. Remove the old key with `ssh-keygen -R remote1` before `just remote-start` of a rebuild (runbook, section 2, step 2): otherwise every login is refused, and `just test-remote` reports only that no SSH login works.

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
| `just remote-apply` says the health timer is not installed yet | The node is not logged in and signed: `just remote-login`, the signature on the laptop, then `just remote-apply` again. The role waits up to a minute for the daemon to settle after a restart; a run that fails there names the daemon's log |
| From the road: which layer refused a connection through the tunnel | The daemon's log, read through pve1: `ssh ops@10.0.10.10 sudo pct exec 3010 -- journalctl -u tailscaled`. The policy's refusals read `Drop: TCP{<source> > 10.0.10.10:<port>} ... no rules matched`, at most one every five seconds after a burst of ten. A line `netstack: could not connect to local backend server at 10.0.10.10:<port>` means the policy let the connection through and a layer behind it refused: the policy is wider than Git (`just tofu tailscale plan`) |
| A ping to pve1 through the tunnel gets no answer | By design: the daemon answers an echo only when its own ping to pve1 succeeds, and the container's filter drops that. Test with TCP (`just test-outside`) |
| A probe of `just test-remote` says `filtered` where the design says open | The container's own filter stopped the user that tried (a silent drop, so it times out): as root only 443 and name lookups are open; the hypervisor's two ports are the tunnel user's. A local TCP drop never returns "permission denied", so the container's layer reads as `filtered`, the same as the hypervisor's; a layers run tells them apart by root reaching the hypervisor's ports only once the container's filter is off |

## Removal

1. Stop the container (`ssh ops@10.0.10.10 sudo pct shutdown 3010 --timeout 60 --forceStop 1`), then remove the device in the Tailscale console.
2. `docs/runbooks/rebuild-remote1.md`, section 3, steps 2 to 4 (protection off, the guest destroyed, the state entry removed); revert the pull requests of R.7 and R.8.
3. The policy: remove the tag's owner, the route's approval and the grant through the tag.
