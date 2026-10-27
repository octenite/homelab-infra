# Component: IoT devices (ESPHome)

Status: the firmware repository exists since 2026-10-27 (ADR 0006), with a file per device and CI that compiles both. Both devices still run firmware built by hand in the ESPHome Device Builder; nothing has been flashed from Git yet (backlog B53). This document is the platform's view. Each device has its own document in `iot/docs/devices/`.

## Purpose

The ESP32 boards that switch things in the house: the room's switch board and the workstation's mains supply today, three or four more later, and the UPS battery sensor of backlog B11 when it is built. They are reached from the phone through their web pages now, and through Home Assistant (B5) later.

## Architecture

- **Devices:** ESP32 boards running ESPHome, in the IoT network (VLAN 60, 10.0.60.0/24), each at an address reserved on the router by hardware address. Known: `esp32-myroom` at 10.0.60.10 (reserved); the workstation mains board, unreserved until B52.
- **Source of truth:** the private repository `homelab-iot`, mounted as the submodule `iot/`. One YAML file per device, built from shared packages (network, web page, diagnostics, board and safe mode) plus the device's own API and OTA blocks and its hardware section. ESPHome is pinned in its `mise.toml`.
- **Secrets:** `iot/secrets.sops.yaml`, encrypted to the operator and recovery age keys. Compiled into each firmware at flash time. Register: `docs/security/secrets-register.md`, section 9.
- **Build and flash path:** branch, `just compile`, pull request, the firmware repository's CI (lint, guard, secret scan, `esphome config` and `esphome compile` of every device with dummy secrets), merge; then from the workstation at home, with a session open, `cd iot && just unlock && just upload <device>`: ESPHome validates, compiles with the real secrets and uploads over the air at the device's reserved address. No hosted runner reaches a device, and CI holds no key.
- **What each device exposes:** its web page on TCP 80 with a digest login and without firmware upload; its native API on TCP 6053 and updates over the air on TCP 3232, both encrypted with the device's key; a fallback hotspot with a password when it loses the network for 90 s.

| From | To a device | Admitted by |
|---|---|---|
| Trusted network (the workstation, the phone at home) | TCP 80, 3232, 6053 | E9: trusted to IoT, everything |
| IoT network | everything | same zone |
| Servers network (Home Assistant, later) | TCP 6053 | a new exception, with B5 |
| Guest, management, remote networks, the internet | nothing | default deny |
| A device, outbound | DHCP, DNS, NTP to the router at 10.0.60.1; the internet, open today | router input rules; E8 until B12 narrows it |

## Dependencies

- The router: the IoT VLAN, its reservations (`templates/router-m30/dhcp.j2`), E9, NTP.
- The workstation at home with a session open (`just session-start`): the operator age key decrypts the device secrets into memory.
- The firmware repository on GitHub, for CI and for the rebuild of a workstation. The devices themselves depend on nothing: they run what they were flashed with.

## Deployment

1. The submodule: `just setup` checks `iot/` out on its `main`; `just private-status` confirms both private repositories.
2. A device: its file in `iot/`, its document in `iot/docs/devices/`, its reservation here (private inventory plus `dhcp.j2`, applied with `just openwrt-apply router-m30`), its rows in the backlog and in section 9 of the secrets register.
3. Its first flash from Git: the device's document, "Deployment". The migration from a hand-built firmware that uses an OTA password is one flash with two extra lines, then a second flash without them.

## Configuration

- Shared behaviour is in `iot/packages/`; a device overrides a value in its own file. ESPHome merges the device file over the packages.
- The address of a device is configured once, in the router's reservation. The device file repeats it as `use_address`, which only tells the esphome tool where to upload.
- Restore modes of switches are decided per circuit and recorded in the device's document before a flash. On the mains board this decides whether the desk loses power at every update.

## Security

- Default deny around the IoT network holds the devices: only the trusted network reaches them (E9), and they reach nothing but the router and, until B12, the internet.
- Each page has a login, each API and each update path is encrypted, each hotspot has a password (B35; the firmware repository's `web.yaml` and the device files). All of this reaches a device with its first flash from Git.
- No secret in plain text on disk: `secrets.yaml` beside the device files is a link to the CI dummies or into the session's memory directory; the repository's guard refuses it in any other form. CI compiles against dummies.
- The firmware repository is private and holds identifiers by design. It is not covered by this repository's public-tree policy, scanners or working-tree secret scan, and has its own.
- What a compromised device can do: operate the other IoT devices and reach the internet. It cannot reach the trusted, management or servers networks. The mains board can cut the workstation's power; its login and encrypted API are the controls, and it is never reachable from the guest network or from outside.
- Not covered yet: Home Assistant's path (B5, a new exception), narrowing the IoT egress (B12), and whether a device page is published on the household path from away (decision H1, which waits for B35 to be live on the device).

## Backup

The configuration is Git. The secrets are in `iot/secrets.sops.yaml` and the owner's password manager (web login, API keys). The devices hold no data. Nothing else exists to back up.

## Restore

- A dead board: a new ESP32 flashed by USB from the same file (`iot/docs/devices/<device>.md`, Restore), its new hardware address put into the reservation.
- A lost workstation: `docs/runbooks/restore-workstation.md` brings back the session; `just setup` brings back `iot/`; nothing on the devices changes meanwhile.
- A lost firmware repository on GitHub: the workstation's clone is a full copy (push it to a new repository and update `.gitmodules`); the devices keep running.

## Troubleshooting

Per device in its document. In general: `cd iot && just secrets-status` says whether the real secrets are unlocked; `just logs <device>` streams a device's log over the API; a device that appears as its own Wi-Fi network has lost the IoT network and opened its fallback hotspot.

## Removal

A device: its file and document in `iot/`, its keys in both secrets files there, its reservation and rows here; erase the board. The whole component: `git submodule deinit iot`, remove the entry from `.gitmodules` and the gitlink, delete the repository on GitHub, remove this document, section 9 of the register and ADR 0006's consequences; the devices keep running until they are erased.

## Record

| Date | Event |
|---|---|
| 2026-10-06 | The first ESP32 joined the IoT network at 10.0.60.10 (B4); the printer at 10.0.60.182 (B17) |
| 2026-10-23 | The owner asked where the ESPHome configuration belongs; a separate private repository was recommended |
| 2026-10-27 | `homelab-iot` created and mounted as `iot/` (ADR 0006): shared packages, two device files without their hardware sections, encrypted placeholder secrets, guard, CI. Both devices still on hand-built firmware |
