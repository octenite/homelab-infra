# Component: OpenWrt router and access points

## Purpose

The D-Link M30 routes between the home networks and the internet, enforces the firewall matrix, and serves DHCP, DNS and time. Two Xiaomi Mi Router 4A Gigabit units extend Wi-Fi as plain access points. All three run OpenWrt 25.12.

## Architecture

- One VLAN-aware bridge on the router carries five networks: management (10), trusted (20), servers (50), IoT (60) and guest (70). The plan and the port table are in [ARCHITECTURE.md](../ARCHITECTURE.md) section 6.
- Six firewall zones, default deny between them and towards the router. Every allow rule carries the ID of its exception, E1 to E13.
- DNS: dnsmasq answers every network and forwards to a local smartdns instance. Client networks cannot use another resolver: such queries are redirected to the router.
- IPv6 is off on every internal network.
- Each access point is connected by a trunk and bridges the trusted, IoT and guest networks between Wi-Fi and the router. It has an address in the management network only, and its own small firewall protects that address.

## Dependencies

- The ISP link: a static address on the WAN port with a cloned MAC address. Both are private inventory variables and must survive every rebuild.
- Nothing inside the lab. The router must work with every other component down.

## Deployment

Ansible, from the operator workstation, never from CI.

- Role `infrastructure/ansible/roles/openwrt_config`: one template per configuration file. Files shared by all access points are in `templates/access-point/`; a file in `templates/<host>/` takes precedence. Per-device values are in `playbooks/host_vars/`.
- Inventory, identifiers and secrets: the private repository, `ansible/inventory/`.
- `just openwrt-check` compares; `just openwrt-apply <host>` applies.

An apply snapshots the current files on the device, starts a five-minute revert timer there, installs the new files, reloads the affected services, logs in again, compares, runs health checks from the device and from the workstation, and only then cancels the timer. If any of that fails, the device restores itself. Each change arms its own flag, so a timer left from an earlier change can never undo a later one.

A change that needs two devices at once, such as an access point and its router port, is applied in four steps: the access point unverified with a long timer, the router unconfirmed with a shorter one, then `just openwrt-confirm` for the access point on its new address, then for the router. If the access point does not answer, nothing is confirmed and both restore themselves.

Extra package on the router: `ip-bridge`, for reading the bridge's address and VLAN tables (`bridge fdb show`, `bridge vlan show`).

## Configuration

| What | Where |
|---|---|
| Network, VLANs, addresses | `templates/<host>/network.j2` |
| Firewall zones and rules | `templates/router-m30/firewall.j2` |
| DHCP pools, static leases, DNS | `templates/router-m30/dhcp.j2` |
| Wi-Fi networks | `templates/<host>/wireless.j2`; names, keys and radio settings in the private inventory |
| SSH and LuCI exposure | `templates/router-m30/dropbear.j2`, `uhttpd.j2` |
| Authorised SSH keys | private inventory, applied by `playbooks/openwrt-ssh-keys.yaml` |

Firmware updates use the router's `owut` tool, which keeps the installed packages and the configuration.

## Security considerations

- SSH on the router is key-only. Two keys are authorised: the operator's and the recovery key.
- LuCI on the router listens on the loopback address and is reached through an SSH tunnel (`just luci`).
- Only the workstation's address may reach the router's SSH and the hypervisor (exceptions E1 to E3). The address is bound to its network card.
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
| The workstation cannot reach the router after a change | Wait five minutes for the revert. Check that the workstation still has its reserved address |
| A client gets no address | `logread -e dnsmasq` on the router; the pool of its network in `dhcp.j2` |
| A connection between networks is refused | Expected by default. Find or add the exception in `firewall.j2` and the matrix |
| What did the last apply do | `logread -e homelab` on the device |

## Removal

Not removable: it is the network. To stop managing a device with Ansible, remove its templates and inventory entry; the device keeps its last configuration.
