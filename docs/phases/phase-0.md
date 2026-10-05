# Phase 0 gate record: discovery and design

Closed: 2026-10-05.

| Gate item | Evidence | Result |
|---|---|---|
| Current state documented | `docs/INITIAL-ASSESSMENT.md` | Done |
| Target architecture documented | `docs/ARCHITECTURE.md` | Done |
| Technology choices recorded | `docs/adr/0001-platform-stack.md` | Done |
| Owner decisions in writing | `docs/ARCHITECTURE.md` section 20, answers dated 2026-10-05 | All fifteen decisions and three follow-ups answered |
| Read-only inventory of the router and access points | `scripts/discovery/openwrt-inventory.sh`; output in the private repository | Done |
| Read-only inventory of Node 1 | `scripts/discovery/pve-inventory.sh`; output in the private repository | Done: a clean Proxmox VE 9.2.2 with no guests |
| Nothing changed on any device | Both scripts are read-only | Confirmed |

## Carried forward

| Item | Goes to |
|---|---|
| Application wishlist | Phase 14 planning; the owner is still exploring |
| Node 2: existing Hyper-V VMs, on-hours, Windows update channel, a week of memory measurements | Phase 3, before the backup server VM is sized |
| The direct 2.5 GbE cable shows no link at either end | Phase 3, physical check |
| Synchronous-write benchmark of the Node 1 SSD | Phase 3 gate |
| Host memory re-measured on the reinstalled host | Phase 3 gate; decides whether the worker VM is 9.0 or 8.5 GiB |
