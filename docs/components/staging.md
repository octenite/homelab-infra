# Component: staging machine `stg1`

## Purpose

A general-purpose Debian server for the owner's company's development team (five to ten people), behaving like the rented cloud servers production runs on: the team deploys containers with Docker and Compose, from GitHub Actions or by hand, and tests as if it were production. Not tied to one application. Test data only. Decided in ADR 0007 (`../adr/0007-staging-vm.md`); exceptions X36 and X37 in `../ARCHITECTURE.md` section 15.

The company's name, its domain, its GitHub organisation and the developers' logins are not in this repository (ADR 0007, decision 6). They are in the private inventory, `private/ansible/inventory/host_vars/stg1/team.yaml`; the developers' handout with the real hostnames is `private/staging/developers.md`. This page says "the company" and `<domain>`.

## Architecture

```text
developer ── HTTPS ──► Cloudflare edge ──► tunnel ──┐
developer ── cloudflared access ssh ─► Access login ─┤ (dialled out by the VM)
GitHub Actions ◄── runner on the VM polls for jobs ──┤
                                                     ▼
                     stg1  10.0.40.10  VLAN 40, zone dmz, guest 4010 on pve1
                       ├─ cloudflared   → localhost services (sites, sshd)
                       ├─ actions-runner (user runner, in group docker)
                       ├─ Docker + Compose: the team's applications
                       └─ sshd: keys only, operator and developers' group
                     fences: router zone dmz (E23 out, E24 in)
                             + pve1's own filter for the device (4010.fw)
```

| Item | Value |
|---|---|
| Guest | VM 4010 `stg1`, pool `staging`, protected against deletion, starts at boot |
| Size | 2 vCPU (`x86-64-v2-AES`), 4096 MiB fixed, 30 GB thin on `local-lvm`, 2 GiB swap file inside |
| OS | Debian 13 genericcloud image, pinned by file name and SHA-512 (`roots/staging/image.auto.tfvars.json` and `pve_vm_images`, compared by `scripts/tofu/lint.sh`) |
| Network | 10.0.40.10/24, gateway, resolver and clock 10.0.40.1; IPv4 only |
| Out (E23) | internet only: tcp 22, 80, 443, 465, 587, 7844; udp 7844 |
| In (E24) | SSH from the workstation's two addresses; nothing else |
| Software | Docker CE, Compose plugin, Buildx (exact versions, `group_vars/staging.yaml`); cloudflared (exact version); GitHub Actions runner (installed version pinned, updates itself); qemu-guest-agent; unattended security upgrades with a reboot at 04:30 when the kernel needs one |
| Time zone | Asia/Kolkata |

Web traffic arrives inside the tunnel, which the VM opens outwards; no port is open on the router or on pve1 for it. The sites' own logins stay as they are: Access guards SSH only, because a login page in front of the sites would block API clients and webhooks.

### Memory

4 GiB is fixed and comes out of pve1's 16 GB whether used or not. Measured after configuration, idle: 476 MiB in use. ERPNext with two sites (database, Redis, workers, web) fits; a third heavy site may not. The re-base of the memory budget with this VM in it is backlog B60, before Phase 5.

## Dependencies

- pve1, VLAN 40 on the router and the bridge (PR of step 1).
- The company's Cloudflare account (tunnel, DNS, Access) and GitHub organisation (login for Access, runner registration, the developers' keys).
- The backup server pbs1, nightly window.

## Deployment

From nothing, at home, with an operator session:

1. `just openwrt-apply router-m30`, `just pve-apply`: the network, the token's right to VLAN 40, pool, firewall file and image.
2. `just tofu staging init`, `just tofu staging plan -out=/dev/shm/stg1.tfplan`, `just tofu staging apply /dev/shm/stg1.tfplan`: the VM, created stopped. Commit the state copy in the private repository.
3. `just pve-apply --check --diff` must show nothing for `4010.fw` (Proxmox reads a guest's firewall file only once the guest exists); then `ssh ops@10.0.10.10 sudo qm start 4010`.
4. `ssh -o StrictHostKeyChecking=accept-new -o HostKeyAlias=stg1 ops@10.0.40.10 true` (remembers the host key), `just staging-apply` twice (the second run changes nothing), `just test-staging`.
5. The owner's steps below.

### The owner's steps

**Tunnel** (Cloudflare dashboard of the company, Zero Trust → Networks → Tunnels):

1. Create a tunnel of type Cloudflared, named `stg1`. Do not run the install command it shows. Copy only the token.
2. Store it: `just secret-set private/ansible/inventory/host_vars/stg1/secrets.sops.yaml staging_vm_tunnel_token` (hidden prompt), then `just staging-apply`. The tunnel shows Healthy.
3. Public hostnames of the tunnel, all one level under the domain (the free certificate covers `*.<domain>`, not deeper):
   - `stg-ssh.<domain>` → `ssh://localhost:22`
   - each site, for example `stg-erp.<domain>` and `stg-erp2.<domain>` → `http://localhost:<port the team's web container publishes>`. The original host name is passed on, so an application that tells tenants apart by host name (Frappe's DNS multitenancy) sees the right one.

**Access for SSH** (Zero Trust):

1. Settings → Authentication → add GitHub as a login method (a GitHub OAuth app of the company's organisation; the dashboard shows the callback URL).
2. Access → Applications → Self-hosted: domain `stg-ssh.<domain>`, session 24 hours; policy "Allow", include "GitHub organization" = the company's organisation. Optionally narrow to one team.

**Runner** (GitHub, organisation settings → Actions → Runners → New self-hosted runner): copy the registration token from the page shown, then `just staging-runner-register` (hidden prompt). In Actions → Runner groups, limit the Default group (or a group of its own) to the company's deployment repositories. A workflow uses it with `runs-on: [self-hosted, staging]`.

**Developers:** one line each in `team.yaml` (`{name: <account>, github: <GitHub login>}`), then `just staging-apply`. Give them `private/staging/developers.md`.

## Configuration

| What | Where |
|---|---|
| The VM's resources, address, image | `infrastructure/opentofu/roots/staging/` (module `modules/pve-vm`) |
| What runs inside | `infrastructure/ansible/roles/staging_vm/`, policy in `playbooks/group_vars/staging.yaml` |
| Company identifiers, team list | `private/ansible/inventory/host_vars/stg1/team.yaml` |
| Tunnel token | `private/ansible/inventory/host_vars/stg1/secrets.sops.yaml`, key `staging_vm_tunnel_token` |
| Network fences | router templates (zone `dmz`, E23, E24); `roles/pve_host/templates/guest-staging.fw.j2` |

A vendor version bump is a pull request that changes the version in `group_vars/staging.yaml`; apt refuses every other version of those packages.

## Fences

What stands between the team and the home is outside the VM, where they cannot change it: the router's zone and pve1's filter on the VM's device (source address and MAC locked, DROP both ways, the same port list). The VM has no filter of its own on purpose: whoever deploys to it is root there.

`just test-staging` (53 checks): the stored configuration, the filter as pve1 reads it, and probes from inside the VM. It must find every address at home closed (pve1, the router on each network, the access points, the workstation's ports, the other zones, the direct link), name lookups possible only at the router, and the internet open only on the listed ports. Passed 53/53 on 2026-11-14.

## Security considerations

- Assume the VM is compromised at any time: it holds test data only, no credential of the lab, and no route home.
- Access's login (GitHub organisation) and sshd's key are two locks; a person who leaves the organisation loses the first at once, and loses the second with the next `just staging-apply` after their line moves to `staging_vm_former_developers`.
- The tunnel token lets its holder run the tunnel elsewhere and receive the sites' traffic. It is readable on the VM by root and the tunnel's user only. Rotation: in the dashboard, "Refresh token", then `just secret-set` and `just staging-apply`.
- The runner runs workflows of the company's repositories as a member of the docker group: anyone who can push a workflow there is root on the VM. Keep self-hosted runners away from public repositories and from pull requests of forks.
- Cloudflare limits a request body to 100 MB on its free plan: larger uploads fail at the edge.

## Backup

Nightly, in the same run as pve1's own configuration (`pbs-host-backup`, 02:30, retried until 03:15): `vzdump 4010 --mode snapshot` to `pbs-node2`, encrypted with the storage's key. The guest agent freezes the filesystems for the snapshot. The success ping fires only when the host and the VM are both backed up, so a missing ping is the alert. The first run is a full copy; later runs send changed blocks.

Not backed up separately: databases inside the team's containers. A restore brings the whole VM back to last night. If the team needs point-in-time database backups, that is theirs to add inside the VM.

## Restore

Whole VM, from the hypervisor (the VM must be stopped; protection prevents an overwrite of a running one):

```sh
ssh ops@10.0.10.10
sudo qm stop 4010
sudo pvesm list pbs-node2 --vmid 4010          # pick the snapshot
sudo qm set 4010 --protection 0
sudo qmrestore pbs-node2:backup/vm/4010/<time> 4010 --force 1
sudo qm set 4010 --protection 1
just pve-apply                                  # from WSL: the firewall file back
just test-staging
```

Never restored yet: the first restore test is owed (into a spare id, 4019, on its own, then deleted).

## Troubleshooting

| Symptom | Look at |
|---|---|
| Sites down, tunnel unhealthy | `systemctl status cloudflared`, `journalctl -u cloudflared`; the VM must reach udp/tcp 7844 out |
| SSH through Access refused | Access's logs in Zero Trust; the person's GitHub login in `team.yaml`; their key published at `https://github.com/<login>.keys` |
| Deploy job waits for a runner | `systemctl status actions-runner`; the runner group's repository list at GitHub |
| Disk full | `docker system df`; the weekly prune runs Sunday 05:00 |
| Out of memory | `free -m`, `docker stats`; swap is 2 GiB |

## Removal

1. Delete the tunnel and the Access application in the dashboard; remove the runner at GitHub.
2. The wrapper refuses `destroy` on this root on purpose, and the module carries `prevent_destroy`. With the owner's explicit yes: `ssh ops@10.0.10.10 'sudo qm set 4010 --protection 0 && sudo qm destroy 4010 --purge'`, then `just tofu staging state rm module.stg1.proxmox_virtual_environment_vm.this` and remove the root in a pull request.
3. Revert the network pull requests (zone `dmz`, E23, E24, VLAN 40 on the bridge, the token's grant), and drop 4010 from `pve_backup_guests`.
