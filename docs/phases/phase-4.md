# Phase 4 gate record: access points

Status: **done on 2026-10-05, except one step that waits for the owner.** The network name in use before the split has not been switched to the guest network yet, because devices are still on it. The plan this record follows is `phase-4-plan.md`.

## What was changed

| Step | Result | Evidence |
|---|---|---|
| 4.0 Fresh encrypted backups of all three devices | Done | `private/openwrt/backups/2026-10-05-pre-phase-4/` |
| 4.1 Both access points modelled completely | Done | Zero differences before the first change |
| 4.2 Two-device apply: unverified apply plus separate confirm | Done, and a bug found and fixed | See "Defect found by the drill" |
| 4.3 Router port to device mapping, measured | Done | lan1 Node 1, lan2 access point 1, lan3 access point 2, lan4 workstation. This differs from the original hardware list, which the plan had followed |
| 4.4 Access point 1 with router port lan2, then access point 2 with router port lan3 | Done | Each pair confirmed only after the access point answered on its new address and matched Git |
| 4.5 IoT network on both access points | Done | Five networks on air per access point |
| 4.5 Old network name switched to guest on all three devices | **Waiting for the owner** | Six devices were still on the old name and none had joined the new main network |
| 4.6 Fixed address for the ESP32 in the IoT network | Done | 10.0.60.10, effective when it joins |
| 4.8 Access point 1 from 25.12.4 to 25.12.5 with `owut` | Done | Same 152 packages before and after; all three devices run 25.12.5 |
| Reboot of each access point | Done | Both returned unattended with five networks on air and matched Git |

What each access point is now: its uplink is a trunk (management untagged; trusted, IoT and guest tagged); it has one address, in the management network (10.0.10.2 and 10.0.10.3); the client networks are bridged without an address; its firewall admits SSH from the workstation only; SSH is key-only; LuCI listens on the loopback address; it takes time and DNS from the router. Access point 2 keeps its second LAN port in the trusted network for the family PC that is wired to it. Access point 1's second port is unused and outside the bridge.

A side effect worth recording: both access points had clocks three months behind, because they could not resolve the time servers' names. They now use the router by address and are correct.

## Tests

| From | Test | Expected | Result |
|---|---|---|---|
| Workstation | SSH to both access points on their management addresses (E2) | allow | pass |
| Workstation | Password login on either access point | refused | pass |
| Workstation | LuCI on either access point | closed | pass |
| Each access point | Package servers over HTTPS (E11) | allow | pass |
| Each access point | Another port to the internet | deny | pass |
| Each access point | Time from the router | allow | pass |
| Node 1, same management network | SSH to either access point | deny | pass |
| Workstation | The access points' old addresses | no answer | pass |
| Router | The wired PC behind access point 2 is learned in the trusted VLAN on port lan3 | yes | pass |
| All three devices | Live configuration equals Git, after firmware update and reboots | yes | pass |

Not yet tested: the guest rules and roaming on each network from a phone. They follow the guest switch.

## Defect found by the drill

A revert timer that belonged to an earlier, confirmed change could undo a later one: every change used the same flag file, so a leftover timer found the later change's flag and acted on it. It surfaced in the drill, on a harmless setting. It did no damage in Phase 2, where the same code ran, but only because no two changes overlapped.

Fix: every change arms its own flag, named with a random token, and its timer acts on that flag only. The confirm step also fails if the flag disappeared while it was verifying, so a revert that fires during verification can no longer be reported as success.

Proof, on access point 1 with a harmless setting: a confirmed change left its timer running; a second change was left pending; the first timer fired; the second change stayed in place and was then confirmed. A change that was left unconfirmed still reverted.

## Open

| # | Item | Who |
|---|---|---|
| 1 | Move trusted devices to the new main network, then say so | Owner |
| 2 | Switch the old network name to the guest network on all three devices, with client isolation; then the guest and roaming tests | Operator, after item 1 |
| 3 | Where the printer goes | Owner; recommendation in backlog B17 |
| 4 | Move the ESP32 to the IoT network | Owner; backlog B4 |
