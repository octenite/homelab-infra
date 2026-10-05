# Phase 2 plan: router segmentation

Status: **preparation done; the changes wait for the owner's "start".** The maintenance window is granted. Steps 2.0 and 2.1 are complete and changed nothing on any device. The design behind this plan is `docs/ARCHITECTURE.md` section 6: the VLAN plan, the port table, the firewall matrix with exceptions E1 to E13, and the DNS, DHCP and NTP rules.

Scope: the D-Link M30, plus one small addition on each access point in step 2.7 (the new main Wi-Fi network). The access points get their VLAN trunks in Phase 4.

## Owner decisions for this phase (2026-10-05)

| Topic | Decision |
|---|---|
| Wi-Fi networks | Three: a new main network with a new name and a generated key (trusted, VLAN 20); the network name and key in use today become the guest network (VLAN 70); a new IoT network with a generated key (VLAN 60). Names and keys are in the private inventory |
| Radio settings | Country code, channels, widths and transmit power stay exactly as they are |
| Router update | Automated, with the router's own `owut` tool, which keeps the installed packages and the configuration |
| Phone to IoT | The phone stays on the main network and must reach IoT devices |

What the Wi-Fi decision means in practice:

- Every device that should be trusted has to be joined to the new main network once, by the owner. Anything left on the old name becomes a guest when that name is switched over.
- The old name is **not** switched to guest in this phase. The access points still bridge it into the trusted network, and they cannot carry a guest VLAN before Phase 4. A device roaming between the router and an access point would otherwise flip between two networks. The switch happens on all three devices at once in Phase 4, after the trusted devices have moved.
- So this phase adds the new main network on the router and both access points, and the IoT network on the router's radios. Phase 4 adds IoT and guest on the access points.

Phone to IoT: the firewall lets the trusted network open connections to the IoT network and never the reverse. This widens exception E9 from "per-device rules" to "trusted may initiate to IoT". Apps that address a device by IP address or through a cloud service work as they are. Apps that find devices by local discovery (mDNS) need a small reflector on the router between the two networks; it is added in step 2.6 if the owner's devices need it.

## What the household will notice

| Step | Effect |
|---|---|
| 2.2, 2.3 | Nothing |
| 2.4 | One reboot of the router: internet and Wi-Fi drop for about two minutes |
| 2.5 to 2.7 | Short interruptions, a few seconds each, while the router reloads its network or Wi-Fi configuration. Up to five of them |
| After the phase | Existing devices keep their addresses and their Wi-Fi network. Two new networks are on air: the new main network and the IoT network |

## Steps

Every step that changes a device follows the same guard: the change is pushed from the wired workstation; a timer on the device restores the previous configuration after five minutes; the timer is cancelled only after the workstation has reconnected and the step's check has passed.

| # | Step | Changes a device | Gate |
|---|---|---|---|
| 2.0 | Encrypted backups of all three devices | No | **Done 2026-10-05.** `private/openwrt/backups/2026-10-05/`, six files, checksums recorded |
| 2.1 | The router's current configuration modelled in Ansible: eight configuration files as templates, with the WAN settings, the cloned MAC, network names and keys in the private inventory | No | **Done 2026-10-05.** `just openwrt-check` reports zero differences in all eight files. A deliberately altered template was reported as a difference, so the check can fail |
| 2.2 | Recovery SSH key (owner creates it; private half in the password manager). Installed next to the lab key on all three devices | Yes, one file each | Login works with the lab key; the recovery key is listed |
| 2.3 | Router SSH becomes key-only. LuCI listens on the router's own address only and is reached through an SSH tunnel | Yes | Password login is refused; LuCI opens through the tunnel; the revert timer is exercised once on purpose |
| 2.4 | Patch update from 25.12.2 to the current 25.12 release with `owut` | Yes, reboot | Version confirmed; `just openwrt-check` again reports zero differences; smartdns and the second-WAN package are still installed |
| 2.5 | The LAN bridge becomes VLAN-aware, with today's network as VLAN 20 untagged on all four ports | Yes | Nothing changes for any client; internet works; addresses unchanged |
| 2.6 | VLANs 10, 50, 60 and 70 with their interfaces; port lan1 (Node 1) becomes management untagged plus servers tagged; firewall zones and the default-deny matrix; IPv6 posture; per-VLAN DHCP; DNS and NTP for every VLAN; forced DNS per client VLAN; the workstation's address reserved | Yes | See "Tests" |
| 2.7 | The new main network on the router and both access points; the IoT network on the router's radios | Yes | A phone joins each and gets an address in the right range; the old network still works |
| 2.8 | Metrics exporter on the router, bound to the servers-side address | Yes, one package | The exporter answers from VLAN 50 only |

Node 1 note: it sits on port lan1 with the address 192.168.1.10 today. Step 2.6 moves that port into the management VLAN, which would cut it off. Before 2.6, Node 1 gets a second, temporary address, 10.0.10.10, so it stays reachable until its reinstall in Phase 3.

## How secrets are handled during the window

The owner opens a session with `just session-start`. It asks for two passphrases and places the SSH agent and the decrypted age key in memory only. Ansible then reads the encrypted inventory. `just session-end` removes the key. Nothing readable is written to disk.

## Tests that close the phase

Run from a client in each network, for IPv4 and IPv6:

| From | Must work | Must be refused |
|---|---|---|
| Trusted (VLAN 20) | Internet; DNS; opening a connection to an IoT device | Management addresses, except from the workstation; the servers network |
| IoT (VLAN 60) | Internet; DNS and time from the router | Opening a connection to trusted, management or servers; the router's SSH and LuCI |
| Workstation | SSH to the router and to Node 1's temporary address | - |
| Any network | - | A router advertisement or any IPv6 path between networks |

Also: forced DNS still redirects a client that tries another resolver; the live configuration equals Git; a full power cycle of the router comes back with everything above intact. The guest network is tested in Phase 4, when it exists.

## Rollback

| Situation | Action |
|---|---|
| A step fails its check | The five-minute timer restores the previous configuration by itself |
| The router is reachable but wrong | `sysupgrade -r` with the archive from step 2.0, as described in `private/openwrt/backups/README.md` |
| The router is unreachable | OpenWrt failsafe mode from the reset button, then the same restore over the wired port |
| The router does not boot | Its second firmware slot, then the D-Link recovery page, then the restore |

## Still needed from the owner

1. The recovery SSH key (step 2.2).
2. The word "start", from the wired workstation, with a session open.
3. How the phone talks to the ESP32 today (which app or firmware), so discovery can be handled in step 2.6.
4. Confirmation that the router's current root password is known. It stays valid on the console and in LuCI.
