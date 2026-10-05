# Phase 4 gate record: access points

Status: **done on 2026-10-05.** The guest switch was applied the same evening, after the owner confirmed it. Two phone checks and two device moves by the owner remain and are listed under "Open". The plan this record follows is `phase-4-plan.md`.

## What was changed

| Step | Result | Evidence |
|---|---|---|
| 4.0 Fresh encrypted backups of all three devices | Done | `private/openwrt/backups/2026-10-05-pre-phase-4/` |
| 4.1 Both access points modelled completely | Done | Zero differences before the first change |
| 4.2 Two-device apply: unverified apply plus separate confirm | Done, and a bug found and fixed | See "Defect found by the drill" |
| 4.3 Router port to device mapping, measured | Done | lan1 Node 1, lan2 access point 1, lan3 access point 2, lan4 workstation. This differs from the original hardware list, which the plan had followed |
| 4.4 Access point 1 with router port lan2, then access point 2 with router port lan3 | Done | Each pair confirmed only after the access point answered on its new address and matched Git |
| 4.5 IoT network on both access points | Done | Five networks on air per access point |
| 4.5 Old network name switched to guest on all three devices, with client isolation | Done | Applied in one run to the router and both access points, each verified and confirmed. Four devices that were still on the old name received guest addresses at once. The owner had moved the workstation and a phone to the main network and accepted that everything else becomes a guest until it is moved |
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

Guest rules, tested after the switch from a temporary address in the guest VLAN on access point 1 (removed afterwards):

| From guest | Expected | Result |
|---|---|---|
| Internet | allow | pass |
| DNS on the router | allow | pass |
| A DNS query addressed to another resolver is answered by the router | forced | pass (the router's redirect counter for the guest network increases) |
| Ping the router; SSH to the router | deny | pass |
| The hypervisor and an access point in the management network | deny | pass |
| The IoT and servers networks | deny | pass |

Client isolation is switched on for the guest network on every radio.

Not yet tested, because it needs real devices: that two guests cannot reach each other, and that a phone keeps its connection when it roams between the router and the access points on each network. A known limit: isolation is enforced by each radio, so two guests on different access points share the guest VLAN on the wire and may be able to reach each other (backlog B19).

## Defect found by the drill

A revert timer that belonged to an earlier, confirmed change could undo a later one: every change used the same flag file, so a leftover timer found the later change's flag and acted on it. It surfaced in the drill, on a harmless setting. It did no damage in Phase 2, where the same code ran, but only because no two changes overlapped.

Fix: every change arms its own flag, named with a random token, and its timer acts on that flag only. The confirm step also fails if the flag disappeared while it was verifying, so a revert that fires during verification can no longer be reported as success.

Proof, on access point 1 with a harmless setting: a confirmed change left its timer running; a second change was left pending; the first timer fired; the second change stayed in place and was then confirmed. A change that was left unconfirmed still reverted.

## Open

| # | Item | Who |
|---|---|---|
| 1 | Move the remaining trusted devices to the new main network. Until then they are guests: internet only | Owner |
| 2 | Join the printer to the IoT network (owner's decision). Its address is then fixed by the operator | Owner, then operator; backlog B17 |
| 3 | Move the ESP32 to the IoT network. Until then it is a guest and the phone shortcuts cannot reach it | Owner; backlog B4 |
| 4 | Phone checks: two guests cannot reach each other; roaming between the three devices on each network | Owner with operator; backlog B19 |
