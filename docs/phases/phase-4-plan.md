# Phase 4 plan: access points

Status: **executed on 2026-10-05; the outcome is in `phase-4.md`.** This file is kept as the plan that was approved. Two things differed in execution: the router ports that lead to the access points are lan2 and lan3, not lan3 and lan4, and the guest switch in step 4.5 waits for the owner.

Goal: both access points carry the trusted, IoT and guest networks on a VLAN trunk; their management moves into the management network; they are hardened like the router; the network name in use before the split becomes the guest network on all three devices at once.

## Before the window

| Needed from the owner | Why |
|---|---|
| Every device that should be trusted is joined to the new main network | After step 4.5 anything on the old name is a guest: internet only, and guests cannot see each other |
| What is plugged into the second LAN port of access point 2 | That port is in use. The design switches unused ports off; a wired device there needs the port kept, in the right network |
| A window of about 60 minutes at the wired workstation, with a session open | Each access point's Wi-Fi drops for about a minute, twice |

## What the household will notice

| Step | Effect |
|---|---|
| 4.4 | Each access point in turn: its Wi-Fi drops for about a minute. Devices roam to the other access point or the router |
| 4.5 | A few seconds per device. From then on the old network name gives internet only |
| 4.8 | Access point 1 reboots once: about two minutes |

## Steps

| # | Step | Changes a device | Gate |
|---|---|---|---|
| 4.0 | Fresh encrypted backups of all three devices | No | Six files and checksums in the private repository |
| 4.1 | Both access points modelled completely in Ansible (seven configuration files each) | No | **Done 2026-10-05.** `just openwrt-check openwrt` reports zero differences on all three devices |
| 4.2 | Two-device apply: an apply that is left unverified on purpose, and a separate confirm. Drilled on one access point with a harmless change | Yes, harmless | The unconfirmed change is restored by the access point; a confirmed one stays |
| 4.3 | Find out which router port leads to which access point, with a bridge diagnostic tool installed on the router | Yes, one package | Port to access point mapping recorded in the private inventory |
| 4.4 | One access point at a time. Access point: VLAN-aware bridge, uplink as trunk, management address 10.0.10.2 or .3, the three client networks bridged without an address, its own firewall admitting only the workstation, SSH key-only, LuCI on loopback. Router: that port becomes a trunk; firewall entries for that access point in E2 and E11 | Yes | See "How one access point is cut over" |
| 4.5 | Wi-Fi: IoT network on both access points (2.4 GHz); the old network name moves to the guest network with client isolation, on all three devices in one run | Yes | A phone on each network gets an address from the right range on every device |
| 4.6 | Fixed address for the ESP32 in the IoT network | Yes | The lease is listed; it takes effect when the device joins |
| 4.7 | Tests | No | See "Tests" |
| 4.8 | Access point 1 from 25.12.4 to 25.12.5 with `owut` | Yes, reboot | Version confirmed; zero differences |

## How one access point is cut over

The uplink changes at both ends, so neither device can verify itself alone. Both carry a revert timer, and both timers are cancelled only by the last step.

1. Apply the new configuration to the access point, unverified, with a 10 minute revert timer. It is now unreachable: it expects a trunk that the router does not offer yet.
2. Apply the router change for that port, unconfirmed, with a 5 minute revert timer. The router's own health checks run as usual.
3. Reach the access point on its new management address through the router, compare it with Git, run its health checks. Cancel its timer.
4. Cancel the router's timer.

If step 3 fails, nothing is cancelled: the router restores the old port within 5 minutes, the access point restores its old configuration within 10, and the pair is back where it started.

## Tests

| From | Must work | Must be refused |
|---|---|---|
| Guest (phone on the old name, on each device) | Internet; DNS | The router, the trusted network, IoT devices, management, another guest device |
| IoT (phone on the IoT network, on each device) | Internet; DNS and time from the router | Opening a connection to trusted, management or servers |
| Trusted (phone on the main network, on each device) | Internet; opening a connection to a device in the IoT network | Management, servers |
| Workstation | SSH to both access points on 10.0.10.2 and 10.0.10.3 | - |
| Any other trusted device | - | SSH or LuCI on an access point |
| Roaming | A phone keeps its address and its connections when it moves between the router and each access point, on each network | - |

Also: the live configuration of all three devices equals Git; a power cycle of each access point comes back with everything intact.

## Rollback

| Situation | Action |
|---|---|
| A cut-over fails its check | Both timers restore the pair by themselves |
| An access point is unreachable after its timer | Failsafe mode and the backup from step 4.0: `docs/runbooks/restore-openwrt.md`, path C |
| Wi-Fi coverage is lost in part of the house | The router's own radios keep all three networks on air throughout |
