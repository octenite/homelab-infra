# Phase 2 plan: router segmentation

Status: **planned, awaiting the owner's go-ahead and a maintenance window.** Nothing in this plan has been applied. The design behind it is `docs/ARCHITECTURE.md` section 6: the VLAN plan, the port table, the firewall matrix with exceptions E1 to E13, and the DNS, DHCP and NTP rules.

Scope: the D-Link M30 only. The two access points keep working unchanged until Phase 4.

## What the household will notice

| Step | Effect |
|---|---|
| 2.1 to 2.3 | Nothing |
| 2.4 | One reboot of the router: internet and Wi-Fi drop for about two minutes |
| 2.5 to 2.7 | Short interruptions, a few seconds each, while the router reloads its network configuration. Up to five of them |
| After the phase | Existing devices keep their addresses and their Wi-Fi network. Two new Wi-Fi networks exist, for IoT devices and guests |

## Steps

Every step that changes the router follows the same guard: the change is pushed from the wired workstation; a timer on the router restores the previous configuration after five minutes; the timer is cancelled only after the workstation has reconnected and the step's check has passed.

| # | Step | Changes the router | Gate |
|---|---|---|---|
| 2.0 | Encrypted backups of all three devices | No | **Done 2026-10-05.** `private/openwrt/backups/2026-10-05/`, six files, checksums recorded |
| 2.1 | Model the router's current configuration in Ansible, including the static WAN address with its cloned MAC, the forced-DNS rules, the smartdns upstream, the disabled second WAN and the radio settings | No | A dry run reports zero differences between Git and the live router |
| 2.2 | Recovery SSH key (owner creates it; private half in the password manager). Install it next to the lab key | Yes, one file | Login works with each key |
| 2.3 | SSH becomes key-only. LuCI listens on the router's own address only and is reached through an SSH tunnel | Yes | Password login is refused; LuCI opens through the tunnel; the revert timer is exercised once on purpose |
| 2.4 | Patch update from 25.12.2 to the current 25.12 release, keeping the configuration | Yes, reboot | Version confirmed; a dry run again reports zero differences |
| 2.5 | The LAN bridge becomes VLAN-aware, with today's network as VLAN 20 untagged on all four ports | Yes | Nothing changes for any client; internet works; addresses unchanged |
| 2.6 | VLANs 10, 50, 60 and 70 with their interfaces; port lan1 (Node 1) becomes management untagged plus servers tagged; firewall zones and the default-deny matrix; IPv6 posture; per-VLAN DHCP; DNS and NTP for every VLAN; the workstation's address reserved | Yes | See "Tests" |
| 2.7 | IoT and guest Wi-Fi networks on the router's own radios | Yes | A phone joins each network and gets an address in the right range |
| 2.8 | Metrics exporter on the router, bound to the servers-side address | Yes, one package | The exporter answers from VLAN 50 only |

Node 1 note: it sits on port lan1 with the address 192.168.1.10 today. Step 2.6 moves that port into the management VLAN, which would cut it off. Before 2.6, Node 1 gets a second, temporary address, 10.0.10.10, so it stays reachable until its reinstall in Phase 3.

## Tests that close the phase

Run from a client in each network, for IPv4 and IPv6:

| From | Must work | Must be refused |
|---|---|---|
| Trusted (VLAN 20) | Internet; DNS; the router as gateway | Management addresses, except from the workstation; the servers network; guest |
| IoT (VLAN 60) | Internet; DNS and time from the router | Trusted, management, servers, guest; the router's SSH and LuCI |
| Guest (VLAN 70) | Internet; DNS | Everything else, including other guests |
| Workstation | SSH to the router and to Node 1's temporary address | - |
| Any network | - | A router advertisement or any IPv6 path between networks |

Also: forced DNS still redirects a client that tries another resolver; the live configuration export equals Git; a full power cycle of the router comes back with everything above intact.

## Rollback

| Situation | Action |
|---|---|
| A step fails its check | The five-minute timer restores the previous configuration by itself |
| The router is reachable but wrong | `sysupgrade -r` with the archive from step 2.0, as described in `private/openwrt/backups/README.md` |
| The router is unreachable | OpenWrt failsafe mode from the reset button, then the same restore over the wired port |
| The router does not boot | Its second firmware slot, then the D-Link recovery page, then the restore |

## What I need from the owner

1. **A maintenance window** of about 90 minutes when a few short internet drops are acceptable, with you at the wired workstation. Steps 2.1 to 2.3 can run any time before it.
2. **The recovery SSH key** for step 2.2. One command, written into the runbook when the step starts.
3. **Names for the two new Wi-Fi networks.** I can generate their passwords and store them encrypted; you read them with your key.
4. **Which devices move to the IoT network now.** The ESP32 at 192.168.1.222 is the candidate. It needs its Wi-Fi credentials changed by you, so it can also wait.
5. **Confirmation that the router's current root password is known to you.** It stays valid on the console and in LuCI, and it is the way back in if both SSH keys are ever lost.
