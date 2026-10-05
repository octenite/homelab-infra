# Phase 2 gate record: router segmentation

Status: **done on 2026-10-05, in one maintenance window.** Two checks need the owner's phone, and one step is deferred. The plan this record follows is `phase-2-plan.md`.

## What was changed

| Step | Result | Evidence |
|---|---|---|
| 2.0 Encrypted backups of all three devices | Done | `private/openwrt/backups/2026-10-05/` |
| 2.1 Router configuration modelled in Ansible | Done | Zero differences before the first change; an altered template was reported |
| Guarded apply built and drilled | Done | A change left unconfirmed on purpose was restored by the router after its timer, with WAN and DNS intact |
| 2.2 Recovery SSH key on the router and both access points | Done | Each device verified by a fresh key login; two authorised keys each |
| 2.3 Router SSH key-only; LuCI on the loopback address only | Done | Password login refused; LuCI closed on the LAN and reachable through an SSH tunnel |
| 2.4 Firmware 25.12.2 to 25.12.5 with `owut` | Done | Same 191 packages before and after; configuration identical to Git afterwards |
| 2.5 VLAN-aware LAN bridge, today's network as VLAN 20 | Done | Clients kept their addresses; both access points and Node 1 stayed reachable |
| 2.6 VLANs 10, 50, 60, 70; six firewall zones; default-deny matrix; per-network DHCP; DNS and NTP for every network; IPv6 off | Done | Matrix tests below |
| 2.7 New main Wi-Fi network on all three devices; IoT network on the router's 2.4 GHz radio | Done | Networks on air on every device; the old network still works |
| Router reboot | Done | All five networks, the firewall, Wi-Fi, DNS and WAN returned unattended; all three devices match Git |
| 2.8 Metrics exporter on the router | **Deferred to Phase 9** | Nothing can scrape it before Prometheus exists; it arrives with its firewall rule |

Node 1 was moved to its management address, 10.0.10.10, before step 2.6 and is reachable there from the workstation only.

## Firewall matrix tests

Run on 2026-10-05 after step 2.6. "Servers" is a temporary client in VLAN 50, created on Node 1 for the test and removed afterwards.

| From | Test | Expected | Result |
|---|---|---|---|
| Management (Node 1) | DNS, ping and NTP from the router | allow | pass |
| Management | HTTP and HTTPS to the internet (E11) | allow | pass |
| Management | Ping the workstation; SSH to an access point | deny | pass |
| Management | Another port to the internet; ping the internet | deny | pass |
| Management | SSH to the router | deny | pass |
| Servers | Ping and DNS on the router | allow | pass |
| Servers | HTTPS to the internet; the two public resolvers (E5) | allow | pass |
| Servers | Another resolver; HTTP to the internet | deny | pass |
| Servers | Trusted network; SSH to the router | deny | pass |
| Servers | Hypervisor API and SSH from a non-worker address | deny | pass |
| Servers | Hypervisor API from a worker address (E6) | allow | pass |
| Servers | Hypervisor SSH from a worker address | deny | pass |
| Trusted (an access point) | Internet; DNS | allow | pass |
| Trusted | SSH to the router; SSH and ping to the hypervisor | deny | pass |
| Workstation | SSH to the router (E1); SSH and web interface of the hypervisor (E2) | allow | pass |
| Workstation | Another hypervisor port; LuCI on the LAN; DNS-over-TLS to the internet | deny | pass |
| Workstation | A DNS query addressed to 8.8.8.8 is answered by the router | forced | pass |
| Workstation | IPv6 default route or global address | none | pass |

Not yet tested, because no client exists in those networks: the IoT rules and the guest rules. See "Open".

## Deviations from the plan and the design

| Planned | Done | Reason |
|---|---|---|
| LuCI bound to the management VLAN address | LuCI bound to the loopback address | It is reached through an SSH tunnel either way; loopback exposes it to no network at all |
| E9: per-device rules from trusted to IoT | Trusted may open connections to the whole IoT network | Owner decision: the phone must reach IoT devices. IoT can never open a connection to trusted |
| IoT egress logged for 14 days (E8) | Not logged | The router keeps its log in memory only; narrowing E8 waits for the device list |
| WAN: ping answered | WAN input dropped entirely, DHCP renewal excepted | Matches the matrix; nothing depended on it |
| Old default rules for IPsec and IPv6 from the WAN | Removed | No IPv6 on the WAN; nothing inbound is possible or wanted |
| Guest network live in this phase | Interface, zone and DHCP exist; no Wi-Fi network yet | The old network name becomes the guest network on all three devices at once in Phase 4 |
| Radio settings in the public templates | Moved to the private inventory | Owner's settings are carried unchanged and are not published. One earlier commit in the public history still shows them, see "Open" |

## Open

| # | Item | Who |
|---|---|---|
| 1 | Join a phone to the IoT network and confirm: it gets an address in 10.0.60.x, the internet works, and it cannot open the router or a trusted device | Owner, then recorded here |
| 2 | Move trusted devices to the new main network at leisure | Owner |
| 3 | How the phone talks to the ESP32, to decide whether an mDNS reflector is needed | Owner |
| 4 | The access points still accept SSH passwords and serve LuCI on the LAN | Phase 4, which the owner agreed to run next, before the hypervisor reinstall |
| 5 | The Wi-Fi country code is visible in one file of one commit in the public history | Owner decides whether the history is rewritten |
| 6 | Guest and IoT matrix tests from a real client | Item 1 for IoT; Phase 4 for guest |

## How to operate what this phase built

```sh
just session-start                 # SSH agent and decrypted key, in memory only
just openwrt-check openwrt         # read-only: do the devices match Git?
just openwrt-apply router-m30      # apply Git, with the five-minute automatic revert
just luci                          # LuCI of the router at https://localhost:8443
just session-end
```
