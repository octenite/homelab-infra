# Component: Tailscale client on the workstation

Status: built in Phase R, step R.3 (2026-10-09). The policies are applied and the empty state is sealed. Open: the check after a restart of Windows, and the login.

## Purpose

The laptop's end of the remote administration path (`docs/adr/0005-administrative-access.md`). At home it does nothing: the client is installed, logged in and disconnected. On a trip it carries SSH and the web interface to the hypervisor through the container `remote1`.

## Architecture

- The official Windows client, version 1.102.4, in `C:\Program Files\Tailscale`. The service `Tailscale` runs as SYSTEM; the tray application runs as the owner.
- The client's settings are forced by system policies under `HKLM\SOFTWARE\Policies\Tailscale`, written by `scripts/node2/tailscale.ps1`. A policy holds for every login profile, needs an administrator to change, and is put back by the service when something edits the preference.
- One setting is left free: accepting subnet routes. `travel.ps1` (step R.9) switches it on for a trip and off at home.
- The node state, which holds the laptop's keys, is sealed with the laptop's TPM (decision D5).
- The laptop accepts no inbound connection from the tailnet. The policy file in Git grants nothing towards it either.

| Policy | Type | Value | Effect |
|---|---|---|---|
| `AllowIncomingConnections` | string | `never` | Shields up: no inbound connection |
| `UseTailscaleDNSSettings` | string | `never` | No name service from Tailscale |
| `UnattendedMode` | string | `never` | The client runs only while the owner is signed in |
| `InstallUpdates` | string | `never` | No automatic update |
| `CheckUpdates` | string | `never` | No update check |
| `AdvertiseExitNode` | string | `never` | The laptop never offers itself as an exit node |
| `PostureChecking` | string | `never` | No device data reported for posture rules |
| `UpdateMenu` | string | `hide` | No update item in the tray menu. The two update policies do not stop an update started by hand there |
| `EncryptState` | number | `1` | The state file is sealed with the TPM |

Refused when found, in this key and in the older key `HKLM\SOFTWARE\Tailscale IPN`: `UseTailscaleSubnets`, `AlwaysOn.Enabled`, `AlwaysOn.OverrideWithReason`, `ReconnectAfter`, `ExitNodeID`, `ExitNodeIP`, `AuthKey`, `LoginURL`, `Tailnet`, `HardwareAttestation`. Each connects by itself, chooses an exit node, carries a key, names another server or takes the route switch away. The script also refuses to run when `C:\ProgramData\Tailscale\syspolicy.json` or `tailscaled-env.txt` exists: either overrides the registry without a trace in it.

## Dependencies

- The Tailscale account and the policy from Git (`docs/runbooks/tailnet-setup.md`).
- A working TPM 2.0 with no pending operation.
- The Windows account of the owner. The client keeps its preferences per Windows user and serves one user at a time.

## Deployment

1. Install `tailscale-setup-1.102.4-amd64.msi` from `https://pkgs.tailscale.com/stable/`. Its SHA-256 is in the settings block of the script. Do not log in. On this workstation many folders under `%LOCALAPPDATA%` are junctions to another drive, and Windows does not let the installer follow one: it fails with error 2330 and the code 448. If `%LOCALAPPDATA%\Tailscale` is a junction (`Get-Item $env:LOCALAPPDATA\Tailscale -Force` shows `LinkType: Junction`), remove the link with `cmd /c rmdir "%LOCALAPPDATA%\Tailscale"`, which leaves the files on the other drive alone, create a normal folder in its place, and install again (seen 2026-10-09).
2. In an elevated PowerShell of the owner's account, in the repository:

   ```
   powershell -ExecutionPolicy Bypass -File scripts\node2\tailscale.ps1
   ```

   It writes the policies, restarts the service once and reads back what the client holds. It ends with a non-zero exit code and lines marked `NOT OK` when something is not as intended.
3. Restart Windows once, then run the script with `-Check`. The state file must still be sealed: this is the test that the firmware TPM keeps its key across a restart.
4. The one login, with the owner at the keyboard:

   ```
   powershell -ExecutionPolicy Bypass -File scripts\node2\tailscale.ps1 -Enrol
   ```

   It refuses unless every check passes and the state is sealed. It prints a browser address, logs in with every setting named, disconnects at once, and prints the laptop's tailnet address. The device then waits for approval in the Tailscale console.
5. The address goes into `infrastructure/opentofu/roots/tailscale/policy.hujson` by pull request.

## Configuration

| What | Where |
|---|---|
| Version pin and installer checksum, the policies, the refused values | `scripts/node2/tailscale.ps1`, settings block |
| What the laptop may reach | `infrastructure/opentofu/roots/tailscale/policy.hujson` |
| Accepting routes, connecting and disconnecting | `scripts/node2/travel.ps1` (step R.9); until then by hand |

A new version is a pull request that changes the pin and the checksum, an install by hand at home, and a run of the script. No policy can pin the version: the script's check is the pin.

Run the script again after every install, repair or upgrade of the client, and use `-Check` whenever in doubt. `-Check` changes nothing.

## TPM

State encryption fails open in the client (read in its source at 1.102.4, and the reason the script checks instead of trusting):

- With the policy set and the TPM not usable, the service keeps the plain file and reports nothing.
- With the policy value missing or of the wrong type at a later start, the service turns the sealed file back into a plain one.
- A sealed file that cannot be opened does not stop the service. It runs with an empty state in memory and a health warning.

So every run checks both the policy value and the shape of `C:\ProgramData\Tailscale\server-state.conf`: sealed means one object with exactly the members `data`, `key` and `nonce`.

What the seal is worth: the file is bound to this TPM and to nothing else, with no start-up secret and no measurement of the boot. It stops a copy of the disk or of the file. It does not stop someone who holds the laptop and starts it (X23): after a loss the device is removed from the tailnet in every case.

A cleared TPM cannot open the file. The laptop then needs a new login and a new approval, and, as the only signer of the tailnet, the disablement procedure at home (decision D4). Before a firmware update, a "reset this PC" or a deliberate clear: set `EncryptState` to `0`, restart the service, check that the file is plain, make the change, then run the script again.

The script does not switch state encryption on while the firmware holds a pending TPM operation, and `-Enrol` refuses without a sealed state. On 2026-10-09 this laptop reported request 5, "clear the TPM", waiting for the next start, with no key press needed for it. The same storage key had been in use since at least 2026-03-25 across about a hundred starts, so the request had either never been carried out or was recent; who made it is not known. The owner had it cancelled the same day: request 0, "no operation", submitted through Windows and read back, and `Get-Tpm` no longer shows a restart pending. To read it again:

```
(Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm | Invoke-CimMethod -MethodName GetPhysicalPresenceRequest).Request
```

Measured on 2026-10-09, with the client logged out and its state empty: the script switched the policy on and the file became sealed; with `EncryptState` set to `0` and a service restart it became plain again, `-Check` reported it, and the next run sealed it again. The service log names each conversion. Still to measure: that the seal survives a restart of Windows.

## Security considerations

- The laptop is the only device that may sign others into the tailnet from step R.4. Its signing key lives in the same sealed file.
- An administrator on the laptop can change every policy. The policies guard against drift, a click and an unprivileged process, not against someone who already controls the machine.
- The client admits traffic for its own tailnet address through a firewall rule of its own. Shields up and the policy in Git are what keeps that closed; Windows allow rules scoped by address are not (see "Away from home" in `pbs.md`).
- Every login creates a new device. `-Enrol` therefore runs only when the client says `NeedsLogin`.
- The script never uses `tailscale up` with settings and never `--reset`: both put accepting routes back to the client's default, which is on.

## Backup

None. The state cannot be restored on another TPM, and it is not copied anywhere on purpose. The policies and the pin are in Git.

## Restore

After a reinstall of Windows, a new laptop or a cleared TPM: remove the old device in the Tailscale console, then follow Deployment from step 1. With node signing on, the new device also needs a signature, and with the laptop as the only signer that is the disablement procedure of `docs/runbooks/tailnet-setup.md`.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| `Tailscale <x> is installed; this script pins <y>` | The client was updated or installed at another version. Install the pinned one, or change the pin by pull request |
| `... holds the value '<name>', which this design never sets` | Something wrote a policy that connects or redirects the client. Find out what, remove the value, run again |
| `state encryption is switched on but ... is plain` | The service could not use the TPM or did not read the policy. Do not log in. Read `C:\ProgramData\Tailscale\Logs\tailscale-service-*.txt` for lines with `TPM` |
| `the firmware holds a pending TPM operation` | See [TPM](#tpm) |
| `the client is '<state>', not 'NeedsLogin'` on `-Enrol` | The laptop is enrolled already. Nothing to do |
| The health line `State store failed to initialize` | The sealed file cannot be opened: the TPM was cleared or replaced. Follow Restore |
| A bare `tailscale up` fails after the key expired | The client wants every non-default setting named. Use the command it prints, which contains `--shields-up` and `--accept-dns=false`, then run the script with `-Check` |

## Removal

1. Remove the device in the Tailscale console.
2. Uninstall the client in Windows, then delete `C:\ProgramData\Tailscale` and `%LOCALAPPDATA%\Tailscale`.
3. `Remove-Item 'HKLM:\SOFTWARE\Policies\Tailscale'`.
4. Remove the laptop's rows from `policy.hujson` by pull request.
