# Initial Assessment (Phase 0)

Status: complete. Date: 2026-10-05. Discovery ran in two passes. The first was from Node 2 without credentials. The second, after the owner installed a lab SSH key, read the router, both access points and the running Node 1 with the scripts in `scripts/discovery/`. Both passes were read-only: nothing was installed, changed or migrated.

The owner answered the design decisions the same day. They are recorded in `ARCHITECTURE.md` section 20 and summarised in section 16 here.

Evidence labels:

| Label | Meaning |
|---|---|
| VERIFIED | Observed by a command on 2026-10-05 |
| OWNER | Stated by the owner on 2026-10-05; not observed |
| RESEARCHED | From a primary source, recorded in `research/2026-10-05-platform-research.md` |
| UNKNOWN | Could not be determined; listed in section 16 |

Raw inventory output contains MAC addresses, network names and serial numbers. It is kept in the private repository, not here.

Companion documents: `ARCHITECTURE.md` (the target design, 20 sections), `adr/0001-platform-stack.md` (technology choices).

## 1. Hardware inventory

### Node 1: primary server (VERIFIED unless marked)

| Item | Value |
|---|---|
| CPU | Intel Core i5-3570, 4 cores / 4 threads; VT-x, EPT and AES-NI present; AVX but no AVX2, so x86-64-v2 only |
| Microcode | Revision 0x21; one vulnerability (SRBDS) is reported as unfixable without newer microcode, which Intel no longer ships |
| RAM | 2 x 8 GB DDR3-1600; 15.55 GiB visible to Linux. 16 GB is the platform maximum (RESEARCHED) |
| Storage | One Crucial BX500 240 GB SATA SSD (223.6 GiB). DRAM-less, no power-loss protection |
| SSD health | SMART passed; 83 % of rated life left; 9911 power-on hours; 414 unclean power losses logged; link running at 3 Gb/s |
| Motherboard | Gigabyte H61M-S1, BIOS F4 dated 2014-09-30, booting in UEFI mode |
| IOMMU | DMAR tables are present, so VT-d is available on this board |
| NIC 1 | Onboard Realtek RTL8168 gigabit, `r8169` driver, linked at 1 Gbit/s to router LAN port 1 |
| NIC 2 | TP-Link TX201, Realtek RTL8125 2.5 GbE, `r8169` driver. No link |
| USB | Bluetooth dongle, Logitech receiver, and a card reader holding a 32 GB boot stick. The Wi-Fi dongle from the hardware list was not attached |
| Power | A whole-home inverter UPS feeds the house. It has no data port. The desktop rides through power cuts (OWNER) |

The direct 2.5 GbE cable between Node 1 and Node 2 shows no link at either end. The cable or a port needs a physical check before Phase 3.

### Node 2: workstation and secondary host (VERIFIED)

| Item | Value |
|---|---|
| Form factor | Lenovo 82EY laptop; personally owned (OWNER) |
| CPU | AMD Ryzen 5 4600H, 6 cores / 12 threads, virtualization enabled |
| RAM | 15.4 GiB usable |
| OS | Windows 11 Enterprise 26H2, build 26300; not domain-, Entra- or workplace-joined |
| Hypervisor | Hyper-V enabled and running; existing VMs could not be listed without elevation |
| WSL2 | Debian 13 with systemd, 8 GiB memory allotted |
| Disk 1 | Samsung 970 EVO Plus 500 GB NVMe: C: (85 GB free of 164) and D: (173 GB free of 300) |
| Disk 2 | Transcend 2 TB SATA SSD: F: "Data-2" (1293 GB free of 1451) and G: "Media" (73 GB free of 412) |
| Disk encryption | BitLocker is off on all four volumes and stays off by the owner's decision |
| NIC in use | Dell D6000 dock gigabit port, 1 Gbps, DHCP address 192.168.1.196 |
| NIC to Node 1 | UE302C USB 2.5 GbE: no link |
| Other NICs | Onboard Realtek gigabit (unused), RZ616 Wi-Fi 6E (disconnected) |
| Time zone | India Standard Time |

### Network devices (VERIFIED)

| Device | Role | Hardware | Software | Free resources |
|---|---|---|---|---|
| D-Link AQUILA PRO AI M30 A1 | Router, DHCP, DNS, Wi-Fi 6 | MT7981, 485 MB RAM | OpenWrt 25.12.2 | 360 MB RAM, 25.6 MB flash overlay |
| Xiaomi Mi Router 4A Gigabit, AP1 | Dumb access point | v1 hardware, 116 MB RAM | OpenWrt 25.12.4 | 42 MB RAM, 6.7 MB flash overlay |
| Xiaomi Mi Router 4A Gigabit, AP2 | Dumb access point | v1 hardware, 116 MB RAM | OpenWrt 25.12.5 | 42 MB RAM, 6.7 MB flash overlay |

AP1 is uplinked on its `lan1` port and AP2 on its `lan2` port.

### Other storage

One 1 TB external USB hard disk (OWNER). The design uses it as a monthly offline copy attached to Node 2.

## 2. Current Proxmox configuration (VERIFIED)

| Item | Value |
|---|---|
| Version | Proxmox VE 9.2.2 on Debian 13.5, kernel 7.0.2-6-pve |
| Address | 192.168.1.10/24 on `vmbr0`, bridged to the onboard NIC |
| Storage | Default layout: 65.6 GiB ext4 root, 8 GiB swap, 130 GiB thin pool `local-lvm`, 16 GiB unallocated |
| Guests | None. No VM, no container, no volume on either storage |
| Users | `root@pam` only; no API tokens |
| Firewall | Disabled |
| Backup jobs | None |
| Time | Asia/Kolkata, synchronised by chrony |
| Idle memory use | About 1.65 GiB with no guests |

The host is a clean default install that holds nothing. The owner approved a reinstall on 2026-10-05. The reinstall is still worthwhile: the default layout gives the root filesystem 65 GiB and the thin pool only 130 GiB, and an unattended install from an answer file in Git makes the host reproducible.

## 3. Current OpenWrt and network configuration (VERIFIED)

- **Router:** one bridge over the four LAN ports, no VLAN filtering. The LAN firewall zone accepts all input and forwarding. The WAN zone rejects input.
- **WAN:** a static private address in 172.16.131.128/26, on a cloned MAC address. The ISP then applies carrier-grade NAT, which a traceroute confirms. A second WAN interface is defined but disabled.
- **IPv6:** no WAN IPv6. A ULA prefix is assigned on the LAN bridge of all three devices, with no router advertisements or DHCPv6 configured.
- **DNS:** the router redirects all LAN DNS to itself, rejects DNS-over-TLS to the internet, and resolves upstream through a local smartdns instance.
- **DHCP:** one pool, 12 hour leases, domain `lan`. The access points have DHCP off.
- **Time:** the router is an NTP client only. All three devices are set to UTC.
- **Management:** SSH password login is enabled on all three devices, and LuCI listens on every interface over HTTP and HTTPS. The lab SSH key is now installed on each.
- **Wi-Fi:** one network name on both bands of all three devices, WPA2 personal. A disabled wireless backhaul interface exists on each.

Consequences: no inbound port forwarding is possible, so nothing in the lab can listen on the internet. The WAN address is outside 100.64.0.0/10, so it does not collide with the address range that mesh VPN products use.

```
             ISP (static private WAN address, then carrier-grade NAT)
                        |
        +---------------+----------------+
        |  D-Link M30, OpenWrt 25.12.2   |   192.168.1.53
        |  DHCP, DNS, Wi-Fi, LuCI, SSH   |   one flat LAN, no VLANs
        +--+--------+--------+--------+--+
      LAN1 |   LAN2 |   LAN3 |   LAN4 |
           |        |        |        |
        Node 1    Node 2    AP1      AP2
        .10       .196      .2       .3
           |        |
           +--------+  direct 2.5 GbE cable, no link today
```

## 4. Existing VLANs

None. Every device shares one layer-2 segment. No bridge VLAN table exists on the router.

## 5. Existing IP ranges

| Range | Use | Evidence |
|---|---|---|
| 192.168.1.0/24 | The only LAN: router .53, access points .2 and .3, Node 1 .10 (static), Node 2 .196 (DHCP), DHCP pool .100 to .249, one ESP32 device at .222 | VERIFIED |
| 172.16.131.128/26 | The router's WAN segment at the ISP | VERIFIED |
| 192.168.199.x | An ISP hop further upstream; the new plan must not collide with it | VERIFIED |
| 172.22.176.0/20 | Hyper-V Default Switch on Node 2 (NAT, local to the laptop) | VERIFIED |

## 6. Existing storage

| Location | Capacity | State |
|---|---|---|
| Node 1 SSD | 223.6 GiB | Proxmox system only; no guest data |
| Node 2 F: | 1293 GB free on a 2 TB SATA SSD, NTFS, unencrypted | Planned as the local backup copy |
| Node 2 C:, D:, G: | 85, 173 and 73 GB free | In personal use; not planned for the lab |
| External disk | 1 TB USB hard disk | Planned as a monthly offline copy |

No backup system exists today for anything in scope.

## 7. Existing services

| Host | Service |
|---|---|
| Router | DHCP, DNS with smartdns upstream, Wi-Fi, SSH, LuCI |
| Access points | Wi-Fi, SSH, LuCI |
| Node 1 | Proxmox VE with no guests |
| Node 2 | Hyper-V, WSL2 Debian |

No homelab workload exists. This is a greenfield build.

## 8. Existing Docker infrastructure

The Docker CLI is installed inside WSL2 Debian on Node 2. The distribution was stopped at discovery time, so no containers were running. Node 1 runs no containers. There is nothing to migrate.

## 9. Existing Cloudflare configuration

The owner has a Cloudflare account with the domain `112511.xyz` (OWNER). The zone carries Zoho mail records that are not in use, and nothing else. The `cloudflared` client is installed on Node 2 (VERIFIED). No tunnel, zone or Access configuration was inspected, because no Cloudflare credentials were used.

The owner chose this domain as the lab zone and accepted the risk that comes with sharing a zone with mail records (`ARCHITECTURE.md` exception X24).

## 10. Existing Git repositories

| Repository | State |
|---|---|
| This repository | Branch `main`, zero commits, no remote. The project instructions file is named `claude.md` in lowercase |
| GitHub | Account exists; `gh` is installed in WSL2; commits will use the owner's GitHub no-reply address |

`claude.md` is renamed `CLAUDE.md` in the first commit, because file-name case matters on Linux CI runners.

## 11. Existing secrets and configuration risks

| # | Finding | Why it matters | Addressed in |
|---|---|---|---|
| 1 | BitLocker is off on every Node 2 volume, and the owner keeps it off | The laptop holds the operator keys, the local backup copy and its mirror | Exception X23: nothing readable is stored on the laptop |
| 2 | The workstation holds SSH keys for unrelated systems | They must never be reused for the lab | A dedicated lab key now exists |
| 3 | One flat network: phones, an IoT device and servers share a segment | No containment if any device is compromised | Phases 2 and 4 |
| 4 | Router and access-point management accepts SSH passwords and serves LuCI to every LAN device | The devices that will enforce segmentation are protected by a password only | Phase 2: key-only SSH, LuCI reachable through SSH only |
| 5 | The LAN firewall zone accepts everything | There is no policy to migrate; the matrix is built from nothing | Phase 2 |
| 6 | Carrier-grade NAT, no IPv6 | No inbound access | Architecture sections 6 and 7 |
| 7 | Node 1's SSD is a DRAM-less budget model with no power-loss protection | It may be too slow for etcd's synchronous writes, and it can corrupt on a power cut | Phase 3 benchmark gate; replacement recommended if it fails |
| 8 | The UPS cannot signal the host | A long outage ends in a hard power-off | A battery-voltage sensor after Phase 4 |
| 9 | Node 1's CPU no longer receives microcode updates | One reported vulnerability cannot be fixed | Exception X13 |
| 10 | Proxmox on Node 1 has its firewall off and a single password-protected root account | Acceptable only until the reinstall | Phase 3 |
| 11 | Node 2 runs Windows build 26300, which may be a preview-channel build | It will be the only local backup target | Open question |
| 12 | Node 2 is a laptop that sleeps and reboots | Nothing on the critical path may depend on it | Architecture section 4 |
| 13 | The lab zone also carries mail records | A cluster credential can edit them | Exception X24, accepted by the owner |
| 14 | The operator toolchain is absent; Terraform is installed, OpenTofu is not | Tooling must be pinned and reproducible | Phase 1 |

No plaintext secret was found in the repository. Wi-Fi keys were redacted on the devices before the inventory output left them.

## 12. Resource constraints

| Constraint | Effect on the design |
|---|---|
| 16 GB RAM on Node 1, not expandable | Two Talos VMs at most; every platform component needs a budget line |
| 4 CPU threads from 2012 | CPU requests are budgeted like RAM; no workload needing AVX2 |
| One 240 GB SATA SSD on a 3 Gb/s link | No storage replication; about 190 GiB of thin pool; bulk media does not fit |
| One 1 GbE uplink from Node 1 | Traffic between VLANs hairpins through the router; east-west traffic stays in one VLAN |
| Access points with 116 MB RAM and 7 MB of free flash | They stay plain access points with a tiny metrics exporter at most |
| Carrier-grade NAT | Outbound-only connections for backups, alerts and any published service |
| Node 2 is an intermittently present laptop | It may hold backups and tooling, never a control-plane role |
| One operator | Updates are reviewed in a monthly window |

Planned memory budget for Node 1, in GiB:

| Line | Planned | With the measured host figure |
|---|---|---|
| RAM visible to Linux | 15.60 | 15.55 |
| Host services, kernel | 1.10 | 1.65 |
| Exporters and page-cache floor | 0.40 | 0.40 |
| QEMU overhead for two VMs | 0.40 | 0.40 |
| Control-plane VM | 3.00 | 3.00 |
| Worker VM | 9.00 | 8.50 |
| Host headroom | 1.70 | 1.60 |

The measured column uses one reading of the default install, 14 minutes after boot. If the reinstalled host measures the same in Phase 3, the worker is created at 8.5 GiB. Inside the worker the platform is budgeted at 5.24 GiB. Practical room for applications is then about 1.8 GiB, down from 2.31. `ARCHITECTURE.md` section 4 carries the trigger and the ordered levers for a tighter result.

## 13. Proposed target architecture

The full design is in `ARCHITECTURE.md`. In one paragraph: Node 1 runs Proxmox VE with two Talos Linux VMs, one control plane and one worker. Cilium is the CNI with default-deny enforced from the first workload. Argo CD reconciles a public Git repository. Secrets flow from SOPS and age (bootstrap, kept in a private companion repository) to OpenBao (runtime) to External Secrets Operator (delivery). Authentik provides identity with MFA. Traefik implements the Gateway API with separate household and admin listeners. The router segments the network into management, trusted, servers, IoT and guest VLANs with a default-deny matrix. Backups are encrypted before they leave the host, land on Node 2 and in Backblaze B2, and are restored on a schedule. Nothing is published to the internet on day one.

Nothing in this design is physically highly available. There is one host, one disk, one router and one uplink. The answer to failure is a rehearsed rebuild from Git plus a restore from backups.

## 14. Migration risks

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| The VLAN cut-over locks the household out of the network | Low / high | Router first and alone; changes pushed over a wired port; timed automatic revert; access points migrated later, one at a time |
| The router loses its internet connection after a change | Low / high | The static WAN address, gateway and cloned MAC are captured as variables before any change and are part of the revert test |
| An existing router feature is dropped by accident | Medium / medium | The forced-DNS rules, the smartdns upstream and the disabled second WAN are modelled in Ansible before the first change; a diff of the live export against Git is the gate |
| The SSD is too slow for etcd | Medium / high | Benchmark in Phase 3, before any cluster exists |
| Memory estimates are wrong | Medium / high | Measure at every phase gate; pre-agreed levers |
| The 2.5 GbE link stays down or is unstable under Hyper-V | Medium / low | Physical check; fall back to the laptop's onboard port |
| Household Wi-Fi coverage drops while an access point is being migrated | Medium / low | Coverage walk beforehand; agreed maintenance windows |
| A young or beta feature on the critical path misbehaves | Medium / medium | Each one has a named gate and a fallback (`ARCHITECTURE.md` section 17) |

Phase 0 itself carried no migration risk: it changed nothing.

## 15. Recommended implementation phases

The order differs from the suggested one in `CLAUDE.md`. Guard rails (secret handling, scanning, dependency updates) come first, the router is segmented before the hypervisor is reinstalled, and backups exist before data does. Reasons are in `ARCHITECTURE.md` section 18; gates are in section 16.

| # | Scope |
|---|---|
| 0 | Discovery, design, owner decisions, device inventories. Complete |
| 1 | Repositories, standards, pinned tooling, SOPS and age custody, CI with all scanners, Renovate |
| 2 | Router: patch update, VLANs, firewall matrix, DNS, DHCP, NTP |
| 3 | Proxmox unattended reinstall and hardening; backup server on Node 2; first host backup |
| 4 | Access points: trunks, network names, IoT device moved |
| 5 | OpenTofu: Talos VMs and Kubernetes |
| 6 | Cilium load-balancer addresses, cluster-wide default-deny, Talos firewall |
| 7 | Argo CD takes ownership; storage driver |
| 8 | cert-manager, OpenBao, External Secrets, first backup jobs |
| 9 | Prometheus, Alertmanager, exporters |
| 10 | Traefik gateway, certificates, split-horizon DNS |
| 11 | PostgreSQL, Authentik, OIDC roll-out, recovery rehearsal |
| 12 | Loki, Alloy, full alert catalogue and runbooks |
| 13 | Hardening and backup audit |
| 14 | Applications, one at a time |
| 15 | Disaster-recovery drill from zero |
| P | Optional: public exposure through Cloudflare Tunnel |
| R | Optional: remote administration |

No phase starts until the previous gate is recorded.

## 16. Decisions, assumptions and open questions

### Decisions taken by the owner on 2026-10-05

The owner accepted the recommended default for all fifteen decisions in `ARCHITECTURE.md` section 20, with these specifics:

- **Node 1** may be wiped for a clean, automated reinstall.
- **Repository layout:** public code plus a private companion repository for ciphertext.
- **Node 2** is personally owned and may host the backup server VM. BitLocker is declined (exception X23).
- **DNS zone:** the existing domain is the lab zone (exception X24).
- **Power:** the home UPS stays; signalling is a later do-it-yourself sensor.
- **Purchases:** FIDO2 security keys later. No other purchase is planned.

### Assumptions that remain

- The reinstalled host uses about as much memory as the default install measured today.
- No existing Hyper-V VM competes for Node 2's memory.
- The owner is the only administrator.
- Data to protect is 60 GB or less at first.

### Still open

1. The application wishlist, with which applications must be public. This is the one input that can invalidate the budgets.
2. Node 2: existing Hyper-V VMs, the hours it is reliably on, and whether its Windows build is a preview-channel build.
3. The number of household users who need accounts, and the volume of data to protect.
4. Why the direct 2.5 GbE cable has no link.

## Appendix: how discovery was done

| Pass | Area | Method |
|---|---|---|
| 1 | Repository | `git status`, `git log`, `git remote -v`, directory listing |
| 1 | Node 2 | CIM queries for system, CPU, disks and volumes; registry read for the Windows version; `dsregcmd /status`; shell volume property for BitLocker |
| 1 | Network from Node 2 | Adapter, address, route and DNS client queries; one ICMP sweep of the LAN; the ARP table; a four-hop traceroute |
| 1 | Router from outside | TCP connect to five ports; one HTTP request to the login page |
| 2 | Router and access points | `scripts/discovery/openwrt-inventory.sh` piped over SSH: release, board, memory, storage, packages, `uci show` with secret values redacted, links, routes, listening sockets |
| 2 | Node 1 | `scripts/discovery/pve-inventory.sh` piped over SSH: versions, firmware, CPU flags, memory, disks, SMART, storage layout, NICs, guests, volumes, users |

Not done: no configuration change on any device, no package install, no benchmark that writes to a disk, no port scan beyond the five router ports.
