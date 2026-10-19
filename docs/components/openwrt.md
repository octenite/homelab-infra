# Component: OpenWrt router and access points

## Purpose

The D-Link M30 routes between the home networks and the internet, enforces the firewall matrix, and serves DHCP, DNS and time. Two Xiaomi Mi Router 4A Gigabit units extend Wi-Fi as plain access points. All three run OpenWrt 25.12.

## Architecture

- One VLAN-aware bridge on the router carries seven networks: management (10), trusted (20), servers (50), IoT (60), guest (70), and the two remote-access networks of Phase R, remote (30) and home_remote (31), which exist on the trunk to Node 1 only. The plan and the port table are in [ARCHITECTURE.md](../ARCHITECTURE.md) section 6.
- Eight firewall zones, default deny between them and towards the router. Every allow rule carries the ID of its exception, E1 to E17. The table below lists them as they are in the template. The zone `home_remote` is in no rule.
- The operator workstation holds two reserved addresses, each bound to one adapter: 192.168.1.196 on the dock port and 192.168.1.197 on Wi-Fi. Every workstation rule on the router and on the access points names both.
- The home desktop holds a reserved address too, 192.168.1.242 on its wired adapter (AP2's access port). No router rule names it. The workstation admits Remote Desktop from it (X34, [remote-desktop.md](remote-desktop.md)).
- DNS: dnsmasq answers every network except `home_remote` and forwards to a local smartdns instance. In `remote` it answers the container's address only. Client networks cannot use another resolver: such queries are redirected to the router.
- IPv6 is off on every internal network: no prefix, no advertisements, no DHCPv6. The older networks still carry the router's link-local address; the two remote-access networks carry none.
- Each access point is connected by a trunk and bridges the trusted, IoT and guest networks between Wi-Fi and the router. It has an address in the management network only (10.0.10.2 and 10.0.10.3), and its own small firewall protects that address.

Exceptions in the router's firewall template (`templates/router-m30/firewall.j2`). "Workstation" means both of its addresses.

| ID | Rule or forwarding | From | To | Admitted |
|---|---|---|---|---|
| E1 | `E1-workstation-to-router-ssh` | Workstation | Router | TCP 22 |
| E2 | `E2-workstation-to-pve1` | Workstation | 10.0.10.10 | TCP 22, 8006 |
| E2 | `E2-workstation-to-access-points` | Workstation | 10.0.10.2, 10.0.10.3 | TCP 22 |
| E2 | `E2-workstation-to-mgmt-ping` | Workstation | Management network | ping |
| E3 | `E3-workstation-to-kubernetes-api` | Workstation | 10.0.50.10 | TCP 6443 |
| E3 | `E3-workstation-to-talos-api` | Workstation | 10.0.50.11, 10.0.50.21 | TCP 50000 |
| E3 | `E3-workstation-to-admin-listener` | Workstation | 10.0.50.201 | TCP 443 |
| E4 | `E4-trusted-to-household-listener` | Trusted network | 10.0.50.200 | TCP 80, 443 |
| E5 | `E5-servers-to-wan-https` | Servers network | Internet, without the provider's side ranges (see E16) | TCP 443 |
| E5 | `E5-servers-to-public-resolvers` | Servers network | 1.1.1.1, 9.9.9.9 | TCP and UDP 53 |
| E6 | `E6-workers-to-pve1-api` | 10.0.50.21, 10.0.50.22 | 10.0.10.10 | TCP 8006 |
| E7 | `E7-workers-to-pve1-exporters` | 10.0.50.21, 10.0.50.22 | 10.0.10.10 | TCP 9100, 9633 |
| E8 | `e8_iot_to_wan` | IoT network | Internet | everything |
| E9 | `e9_trusted_to_iot` | Trusted network | IoT network | everything |
| E10 | Not on the router | | | The direct link between hypervisor and workstation, enforced on those hosts: [pbs.md](pbs.md), Fences |
| E11 | `E11-mgmt-hosts-to-wan-updates` | 10.0.10.10, 10.0.10.2, 10.0.10.3 | Internet, without the provider's side ranges (see E16) | TCP 80, 443 |
| E12 | `E12-pve1-to-household-listener` | 10.0.10.10 | 10.0.50.200 | TCP 443 |
| E13 | `E13-talos-to-pve1-ntp` | 10.0.50.11, 10.0.50.21 | 10.0.10.10 | UDP 123 |
| E14 | `E14-pve1-to-backup-server` | 10.0.10.10 | Workstation | TCP 8007 |
| E15 | `E15-remote1-to-pve1` | 10.0.30.10 | 10.0.10.10 | TCP 22, 8006 |
| E16 | `E16-remote1-to-wan-https` | 10.0.30.10 | Internet, without the private, link-local and carrier ranges on the provider's side | TCP 443 |
| E17 | `E17-workstation-to-remote1-ssh` | Workstation | 10.0.30.10 | TCP 22 |
| - | `Router-DNS-remote` | 10.0.30.10 | Router, 10.0.30.1 | TCP and UDP 53. Unlike the other `Router-...` rules it names one address, not a zone |

Not exceptions: the trusted and guest networks reach the internet, and every zone reaches the services the router itself offers to it (rules named `Router-...`). E7 in ARCHITECTURE.md also names the exporters of the access points and the router. No rule for them is in the template today.

On each access point (`templates/access-point/firewall.j2`): `E2-workstation-ssh` admits TCP 22 from the workstation, and the router and the workstation may ping.

## Dependencies

- The ISP link: a static address on the WAN port with a cloned MAC address. Both are private inventory variables and must survive every rebuild.
- Nothing inside the lab. The router must work with every other component down.

## Deployment

Ansible, from the operator workstation, never from CI.

- Role `infrastructure/ansible/roles/openwrt_config`: one template per configuration file. Files shared by all access points are in `templates/access-point/`; a file in `templates/<host>/` takes precedence. Per-device values are in `playbooks/host_vars/`.
- Inventory, identifiers and secrets: the private repository, `ansible/inventory/`.
- `just openwrt-check <target>` compares; `just openwrt-apply <target>` applies; `just openwrt-ssh-keys` installs the authorised keys. Targets are `router-m30`, `ap1`, `ap2` or a group (`openwrt`, `openwrt_routers`, `openwrt_aps`). All of them need an open session (`just session-start`).

An apply snapshots the current files on the device, starts a five-minute revert timer there, installs the new files, reloads the affected services, logs in again, compares, runs health checks from the device and from the workstation, and only then cancels the timer. If any of that fails, the device restores itself. Each change arms its own flag, so a timer left from an earlier change can never undo a later one.

A change that needs two devices at once, such as an access point and its router port, is applied in four steps: the access point unverified with a long timer, the router unconfirmed with a shorter one, then `just openwrt-confirm` for the access point on its new address, then for the router. If the access point does not answer, nothing is confirmed and both restore themselves.

Extra package on the router: `ip-bridge`, for reading the bridge's address and VLAN tables (`bridge fdb show`, `bridge vlan show`).

## Configuration

| What | Where |
|---|---|
| Network, VLANs, addresses | `templates/router-m30/network.j2`; `templates/access-point/network.j2` for both access points |
| Firewall zones and rules | `templates/router-m30/firewall.j2` |
| DHCP pools, static leases, DNS | `templates/router-m30/dhcp.j2` |
| Wi-Fi networks | `templates/<host>/wireless.j2`; names, keys and radio settings in the private inventory |
| SSH and LuCI exposure | `templates/router-m30/dropbear.j2`, `uhttpd.j2` |
| DHCP reservations of the workstation's two adapters and the home desktop | `templates/router-m30/dhcp.j2`; the adapters' hardware addresses in the private inventory |
| Authorised SSH keys | private inventory, `ansible/inventory/group_vars/all/ssh.yaml`, applied by `just openwrt-ssh-keys`. The hypervisor and the backup server read the same list |

Firmware updates use the router's `owut` tool, which keeps the installed packages and the configuration.

## Security considerations

- SSH on the router is key-only. Two keys are authorised: the operator's and the recovery key. `just openwrt-ssh-keys` refuses a list with fewer than two keys or without a key that is loaded in the agent, and the device restores its previous key file after two minutes unless a fresh login succeeds. Replacing a key: [operator-key-compromised.md](../runbooks/operator-key-compromised.md).
- LuCI on the router listens on the loopback address and is reached through an SSH tunnel (`just luci`).
- Only the workstation's two addresses may reach the router's SSH, the access points and the hypervisor (exceptions E1 to E3). Each address is bound to one adapter of the workstation by a DHCP reservation.
- The root password still works on the serial console and in LuCI. It is the way in if both keys are lost.
- The access points are hardened the same way: key-only SSH, LuCI on loopback, and a firewall that admits only the workstation.

## Backup

`private/openwrt/backups/<date>/`: per device, the full configuration export and the device's own backup archive, both SOPS-encrypted, with checksums. Taken before each phase that changes a device. The templates in Git are the primary source; the backups cover everything outside them.

## Restore

[restore-openwrt.md](../runbooks/restore-openwrt.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| An apply reports "does not match Git" after the change | The diff is printed. The device reverts by itself unless confirmed |
| The workstation cannot reach the router after a change | Wait five minutes for the revert. Check that the workstation still holds one of its reserved addresses, 192.168.1.196 or 192.168.1.197 |
| The router was switched off and on while a change waited for its confirmation | The revert is gone: the snapshot and its timer live in memory, and the router started with the new files. Nothing confirmed them. Run `just openwrt-check openwrt_routers` and decide: keep, or restore from the backup of the phase. Do not power-cycle the router within ten minutes of an apply |
| A client gets no address | `logread -e dnsmasq` on the router; the pool of its network in `dhcp.j2` |
| A connection between networks is refused | Expected by default. Find or add the exception in `firewall.j2` and the matrix |
| What did the last apply do | `logread -e homelab` on the device |
| Does a change open the router for a moment | No. A firewall change is loaded by a reload, which replaces the rule table in one step (since 2026-10-11; a restart, used before, left the router without rules for about half a second). A change to the network file still restarts the network: clients pause for about ten seconds |

## Removal

Not removable: it is the network. To stop managing a device with Ansible, remove its templates and inventory entry; the device keeps its last configuration.
