# Component: Remote Desktop into the workstation

Status: built and in use since 2026-10-19 (owner decision the same day). The reservation, the workstation's side and the first connection from the desktop are proven. See "Record" at the end.

## Purpose

The home desktop opens a Remote Desktop session on the workstation (Node 2), inside the house. The direction is one way, by the owner's decision of 2026-10-19: the desktop controls the workstation. The workstation does not control the desktop.

Why Windows' own Remote Desktop: both ends have it already. The workstation runs Windows 11 Enterprise, which accepts connections, and the desktop runs Windows 11 Pro, whose `mstsc` connects. Nothing is installed, no account or outside service is involved, and the login is checked before a session exists (Network Level Authentication). The alternatives:

| Option | Why not |
|---|---|
| RustDesk | Needed only when the computer being controlled runs Windows Home. It adds an agent, and it talks to RustDesk's public ID server unless one is self-hosted |
| Sunshine and Moonlight | Game streaming with the graphics card's encoder; more than desktop work needs |
| AnyDesk, TeamViewer, Chrome Remote Desktop | Every session is brokered through the vendor's servers and an account there |

## Architecture

- **The desktop:** Windows 11 Pro, wired to AP2's access port, in the trusted network (VLAN 20). The router binds 192.168.1.242 to its wired adapter with a reservation. That is the address it held when the reservation was made, so nothing changed on the desktop. Its hardware address was read in AP2's bridge table on 2026-10-19 (port `lan1`, 1 Gbit/s).
- **The path:** the desktop, AP2's access port, the trunk to the router, the router's bridge, port lan4, the workstation's dock adapter (192.168.1.196). The traffic stays inside the trusted network: it is bridged, not routed, and no router firewall rule takes part. Over the workstation's Wi-Fi adapter (192.168.1.197) the path is the same.
- **The workstation:** Windows' `RDP-Tcp` listener on TCP and UDP 3389. Network Level Authentication is on, and the connection uses TLS with a self-signed certificate that Windows creates. `scripts/node2/rdp.ps1` switches it on and holds the settings below.

Windows Firewall rules that `rdp.ps1` maintains (all inbound, port 3389):

| Rule | Action | From | To | Profile |
|---|---|---|---|---|
| `rdp-desktop-tcp`, `rdp-desktop-udp` | allow | 192.168.1.242 | 192.168.1.196 and .197 | Private only |
| `rdp-others-tcp`, `rdp-others-udp` | block | every IPv4 address except 192.168.1.242, and every IPv6 address | any | any |
| Windows' own `RemoteDesktop-UserMode-In-TCP`, `-UDP`, `RemoteDesktop-Shadow-In-TCP`, `RemoteDesktop-In-TCP-WSS` | kept off | | | |

The allow rules name the workstation's own two home addresses and the Private profile. Together these mean "at home": Windows starts a network it has not seen before as Public, and a foreign network hands out .196 or .197 only by chance. The block rules win over any allow rule. They still hold when the Remote Desktop switch in Settings turns Windows' own rules back on, which admit every address on every profile.

The rule names start with `rdp-`, not `homelab-`. `pbs-vm.ps1` removes every `homelab-*` rule that it does not manage itself.

| Layer | What it holds |
|---|---|
| The router's reservation | 192.168.1.242 belongs to the desktop. It is not a control: any device in the trusted network can set that address by hand |
| Windows Firewall, allow | only from 192.168.1.242, only to the two home addresses, only on a Private network |
| Windows Firewall, block | every other source, both address families, every profile |
| Network Level Authentication and the account's password | the login, before a session exists. After 10 failed attempts the account is locked for 10 minutes (the Windows defaults, read on 2026-10-19) |

**Who may log in:** members of Administrators and Remote Desktop Users. On 2026-10-19 that is the owner's local account alone, in both groups. The built-in Administrator and Guest accounts are disabled. The account has a password, and Windows refuses an empty password over the network (`LimitBlankPasswordUse` 1). The PIN does not work over Remote Desktop.

**One session at a time.** The remote session is the owner's own Windows session. When the desktop connects, the workstation's screen locks and the session moves to the desktop. Signing in at the workstation takes it back.

## Dependencies

- The router's reservation (`templates/router-m30/dhcp.j2`; the hardware address `openwrt_desktop_mac` in the private inventory).
- The workstation at home, awake, with the network that holds 192.168.1.196 or .197 set to Private in Windows.
- The owner's Windows account and its password.

## Deployment

1. The reservation on the router, with a session open:

   ```sh
   just openwrt-check router-m30
   just openwrt-apply router-m30
   ```

   The difference shown is the one host entry `desktop`. A DHCP change reloads dnsmasq; the network is not restarted.
2. The workstation, in an elevated PowerShell, in the repository:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\node2\rdp.ps1
   ```

   It switches Remote Desktop on, starts the service, writes the rules, reads everything back and prints the certificate's thumbprint. It ends with lines marked `NOT OK` and exit code 1 when something is not as intended. `-Check` changes nothing.
3. The first connection, at the desktop: press Win+R, run `mstsc`, choose "Show options", enter computer `192.168.1.196` and user name `<workstation name>\<account>` (the workstation's name is in Settings, System, About; the names stay out of this repository). Leave "Allow me to save credentials" unticked. When the certificate warning appears, choose "View certificate", then "Details", then "Thumbprint". It must be the thumbprint that `rdp.ps1` printed. Only then tick "Don't ask me again for connections to this computer" and connect. The connection can be saved as an `.rdp` file on the desktop. The file holds no password.
4. Checks:
   - At the desktop, in PowerShell: `Test-NetConnection 192.168.1.196 -Port 3389` shows `TcpTestSucceeded : True`.
   - In WSL: `just test-fences`. Port 3389 on the workstation stays closed to the hypervisor and silent to the router.

## Configuration

| What | Where |
|---|---|
| The desktop's address, the workstation's two home addresses, the port, the login settings, the rules | `scripts/node2/rdp.ps1`, settings block |
| The reservation | `infrastructure/ansible/roles/openwrt_config/templates/router-m30/dhcp.j2`; the hardware address in `private/ansible/inventory/host_vars/router-m30/identifiers.yaml` |

A change of the desktop's address changes `$Desktop` in the script and the reservation together, in one pull request.

Run the script again after a feature update of Windows, after anyone used the Remote Desktop switch in Settings, and whenever in doubt (`-Check`).

## Security considerations

- Exception X34 (`docs/ARCHITECTURE.md`, section 15).
- **What a connection gives.** It gives the owner's Windows session, which is an administrator, and with it the admin environment: WSL and the operator's keys. While an operator session is open, it also gives the SSH agent with the key loaded and the decrypted age key. At the desktop, the password is therefore the whole protection:
  - The password is never saved in `mstsc` on the desktop.
  - The operator session ends with `just session-end` when the work is done, and the remote session is signed out or disconnected when you leave the desktop.
- **By address.** Any device in the trusted network that takes 192.168.1.242 while the desktop is off reaches the login prompt (the same class as X9). It then still needs the password, and the lockout limits guessing.
- **Away from home.** The allow rules need the Private profile and one of the two home addresses, and a foreign network starts as Public. Residue: a foreign network marked Private by hand, which hands the laptop .196 or .197 and has a host at .242, reaches the login prompt. `rdp.ps1 -Off` before a trip closes even that. Whether `travel.ps1 -Away` should do this is backlog B50.
- **Tailscale.** No path. The client accepts no inbound connection (shields up), and its addresses are in no allow rule.
- **The backup VM and the direct link.** No path. Every connection from them is blocked by `pbs-vm.ps1`'s rules `homelab-block-backup-vm` and `homelab-block-direct-link`.
- **The certificate** is self-signed and created by Windows. If Windows creates a new one (after a reinstall, for instance), the warning returns at the desktop. Compare the thumbprint again. If it does not match what `rdp.ps1` prints, do not connect.
- **Audit.** Each Remote Desktop logon is event 4624 with logon type 10 in the Security log. Session events (21 logon, 24 disconnect, 25 reconnect) are in the log `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational`, with the source address:

  ```powershell
  Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -MaxEvents 20 | Format-List TimeCreated, Id, Message
  ```

- **The desktop** is a household machine. This repository does not manage it.

## Backup

None. The configuration is in Git. The certificate is not kept: a new one only means comparing the thumbprint again.

## Restore

- **Windows reinstalled on the workstation:** run `rdp.ps1`, then compare the new thumbprint at the desktop's next connection.
- **New desktop or new network card:** put its hardware address into `openwrt_desktop_mac` and apply the router (Deployment, step 1). A different address means changing `$Desktop` and the reservation together.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| The desktop cannot connect | On the workstation, run `rdp.ps1 -Check`. On the desktop, `ipconfig` must show 192.168.1.242. The workstation must be awake, at home, and on a Private network |
| It works on the dock and not on Wi-Fi | Windows treats the main Wi-Fi network as Public on this laptop (read on 2026-10-19; the wired network is Private), and the allow rules want Private. The script prints a `note:` line about it. Use the dock, or make the main Wi-Fi network Private in Settings (Network and internet, Wi-Fi, the network, "Private network") |
| "Your credentials did not work" | The user name is `<workstation name>\<account>`, not the desktop's name, and the password is the account's password, not the PIN. After 10 failures within 10 minutes the account is locked for 10 minutes, and a successful sign-in resets the count. To tell a wrong name from a wrong password without elevation, read the account's counter on the workstation: `([ADSI]"WinNT://$env:COMPUTERNAME/<account>,user").BadPasswordAttempts`. It rises by one per attempt when the name reaches the account and the password is wrong; it stays where it is when the name does not reach the account |
| The certificate warning comes back | Windows made a new certificate. Compare the thumbprint with what `rdp.ps1` prints. If they differ, find out why before connecting |
| `the built-in rule ... is on` | Someone used the Remote Desktop switch in Settings. The block rules held anyway. Run `rdp.ps1` to switch the rule off |
| `Remote Desktop is switched off` | The switch in Settings, or `-Off`. Run `rdp.ps1` |
| `nothing listens on TCP 3389` | The service did not open its listener. `Get-Service TermService`; read the System log for TermService errors |

## Removal

1. `powershell -ExecutionPolicy Bypass -File scripts\node2\rdp.ps1 -Off`. This switches off the listener and removes the allow rules.
2. `Get-NetFirewallRule -Name 'rdp-*' | Remove-NetFirewallRule`.
3. By pull request: delete the script and this document, the `desktop` reservation in `dhcp.j2`, `openwrt_desktop_mac` in the private inventory, and X34. Then apply the router.

## Record

2026-10-19, with an operator session open (pull request 54):

| Step | Result |
|---|---|
| `just openwrt-check router-m30` before | one difference: the host entry `desktop`; every other file identical |
| `just openwrt-apply router-m30` | matches Git, health checks passed, revert disarmed; `uci show dhcp.desktop` shows the reservation |
| `rdp.ps1` | 6 changes: switched on, service started, the four rules; listening on TCP and UDP 3389 |
| `rdp.ps1 -Check`, then a second plain run | nothing changed, exit code 0 |
| Drift: Windows' own `RemoteDesktop-UserMode-In-TCP` switched on by hand, as the switch in Settings does | the router's probe of 192.168.1.196:3389 stayed silent while the listener was up, so the block rule held; `-Check` reported the rule and ended with exit code 1; a plain run switched it off |
| `just test-fences` | `fences hold: 23 probes`. Port 3389: hypervisor to 10.0.99.2 filtered, to 192.168.1.196 refused (by the router's zone rule), router to 192.168.1.196 silent |
| The first connection from the desktop | verified by the owner: the session log shows sessions from 192.168.1.242 from 08:35 IST on, and the failed-password counter back at 0 after the first successful one (read 2026-10-20) |

After a restart of Windows (2026-10-19 08:23 IST) the service started by itself: the listener was up 18 seconds after the start, before anyone had signed in. No automatic start type is needed.

The owner's first attempts from the desktop that morning reached the account and were refused on the password: the account's failed-password counter rose by one per attempt (Troubleshooting, the credentials row).
