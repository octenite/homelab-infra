# Component: travel mode

Status: built in Phase R step R.9 and passed its gate on 2026-10-16: `just test-travel`, 38 checks, and one owner-run cycle of `-Away` and `-Home` (the record is the R.9 row of `docs/phases/phase-r-plan.md`). The same from an outside network is step R.10.

## Purpose

Two postures for the laptop, which is also the workstation (Node 2): at home the administration path is direct; away it goes through the tunnel and the container `remote1` (`docs/adr/0005-administrative-access.md`, `docs/phases/phase-r-plan.md`, "Home and away"). Travel mode switches between them in one command each way, and keeps the tooling from making changes to the hypervisor from the road.

## Architecture

Four parts, one question underneath them all.

**The question: does pve1 see this laptop arrive through the tunnel?** `scripts/ops/away-check.sh` logs in to pve1 and reads `$SSH_CONNECTION`, which names the address pve1 sees. 10.0.30.10, the container's address, means the tunnel: either away, or at home with Tailscale connected and the route accepted (accepting the route makes Windows send everything for pve1 through the tunnel, because the route is more specific than the home network's). Any other address means the direct path. No answer means "unknown". Nothing about it is stored: every guard asks again.

**The guards.** What each one does with the answer, following the table in the plan:

| Tool | Home | Away (tunnel) | Unknown |
|---|---|---|---|
| The four hypervisor plays (`pve-apply`, `pve-tokens`, `pve-backup-init`, `pve-bootstrap`) | run | refused, by their first task (role `away_guard`); `--check` runs | refused |
| `just tofu remote apply` and every other verb that writes | run | refused by the wrapper (`scripts/tofu/run.sh`) before any secret is loaded | refused |
| `just tofu remote plan` and other reading verbs | run | run | run |
| `just pve-media` (`scripts/pve/build-install-media.sh`) | runs | refused | **runs**: unknown is the disaster-recovery case, in which this script builds the image on the backup VM because pve1 is dead |
| `just session-start` | 12 hours | 2 hours, and ending the session disconnects Tailscale | 2 hours, like away |
| `just nesting-probe` (it creates a guest) | runs | refused | refused |
| `just tofu pve`, `just tofu tailscale` | run | run | run |

The play guard reads the variable as the connection user, because sudo clears it from the environment. The hypervisor group sets `ansible_become`, and a connection variable outranks the task's `become` keyword, so the guard's task turns become off with the variable (`vars: ansible_become: false`); the keyword alone would read nothing and refuse every run. An empty value is refused because it proves nothing. Its two tasks carry the tags `always` and `away-guard`: they run whatever `--tags` selects, and `--tags away-guard` runs the facts, the guard and the roles' argument checks (on the workstation), and nothing else on the host. That is how the gate test shows a refused real run without any other task being able to start. Flags that skip a play's first tasks on purpose, `--start-at-task` and `--skip-tags always`, skip the guard too: it stops a run started by habit, not a decision.

**`scripts/node2/travel.ps1`**, in an elevated PowerShell on the laptop, with its WSL half `scripts/node2/travel.sh`:

- `-Away`, at home before leaving. Refuses, before changing anything, when: the laptop holds neither of its home addresses; an operator session is open; the backup VM's management window is open; Windows waits for a restart it may start by itself (Windows Update, servicing, or the update orchestrator); `tailscale.ps1 -Check` fails; the laptop's node key has expired. Warns when the key expires within 14 days (D7). Then it loads the SSH key into an agent of its own (one passphrase), checks that pve1 sees the direct path, records whether the backup VM runs and shuts it down, converges `pbs-vm.ps1 -Away` (no backup port forward), starts the container, connects Tailscale with the route accepted, and proves the path: the container online with its tag and route, pve1 seeing this laptop arrive from 10.0.30.10, and the container reporting to its health check.
- `-Home`, back on the home network. Disconnects Tailscale first, so that the next SSH goes direct, stops the container, converges `pbs-vm.ps1` (the forward comes back), starts the backup VM if it ran before the trip, and reminds you to pause the health check.
- `-Connect` and `-Disconnect`: the tunnel alone, no elevation. Away, after a session has ended and taken the tunnel with it, `-Connect` brings it back.

**The away session** (`scripts/ops/session.sh`): `start` asks pve1 once the SSH key is loaded. Away or unknown, the session's timer ends it after 2 hours, and a marker inside the session makes its end, by hand or by the timer, disconnect the Windows client through WSL interop (`tailscale set --accept-routes=false`, `tailscale down`, both read back). Before it asks, `start` arms a 2-hour timer and the marker, so that an interrupted question still leaves a session that ends and takes the tunnel with it. The SSH key keeps its 12-hour lifetime in the agent as a fallback: changing it after asking pve1 would ask for the passphrase a second time, so the 2-hour bound is the timer's. What the timer says when it ends a session goes to `/dev/shm/homelab-session-end.log`, shown by `just session-status` and by the next `just session-start`.

## Dependencies

- Steps R.5 to R.8: the router's zone, the hypervisor's filter, the container, its tunnel and its signature.
- The operator SSH key in WSL (`~/.ssh/homelab_ed25519`) and the WSL Debian distribution as the default one: `travel.ps1` reaches WSL with `wsl.exe -e`.
- `scripts/node2/tailscale.ps1` (`-Check`) and `scripts/node2/pbs-vm.ps1` (`-Away`, plain), which `travel.ps1` runs as child processes.
- The container's health timer (a ping address stored for `remote1`), for the report `-Away` sends.

## Deployment and use

Nothing is installed: the scripts run from the working copy.

Before leaving, at home, with the operator session closed (`just session-end`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\node2\travel.ps1 -Away
```

It asks for the SSH key's passphrase once and ends with `AWAY:` and a summary, or with `*** NOT READY TO TRAVEL ***`, the failed check, and the tunnel and container left as they are so that you can look. From that moment, also while still at home, real runs against pve1 are refused.

On the road: `just session-start` gives a 2-hour session; `just session-end`, or the end of the 2 hours, disconnects Tailscale. To work again: `travel.ps1 -Connect`, then `just session-start`.

Back home:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\node2\travel.ps1 -Home
```

Then pause the container's health check in the healthchecks.io console, as `-Home` reminds you.

## Configuration

| What | Where |
|---|---|
| The tunnel's source address (the container's) | `scripts/ops/away-check.sh` (`TUNNEL=`), checked against the OpenTofu root by `just tofu-lint`; the play guard takes `pve_remote_admin` |
| The laptop's home addresses, the container's name, tag and route, the key warning (14 days) | the settings block of `scripts/node2/travel.ps1` |
| Session lengths (12 hours at home, 2 away) | `scripts/ops/session.sh`; `HOMELAB_SESSION_HOURS` sets the length in every case |
| The lifetime of the agent a run of `travel.ps1` brings (15 minutes) | `scripts/node2/travel.sh` |
| Whether the backup VM ran before the trip | `C:\ProgramData\homelab\travel-state.json`, written by `-Away` if absent, deleted by `-Home` |

## Security considerations

- **The laptop does not leave with secrets in memory.** `-Away` refuses an open operator session. For its own SSH it loads the key into an agent that holds only the SSH key, never the age key, for at most 15 minutes, and stops it before it ends.
- **No mode is stored.** The guards ask pve1 every time. The one fact kept between `-Away` and `-Home`, whether the backup VM ran, decides nothing about home or away.
- **Fail-safe direction.** When pve1 cannot be asked, every guard that could change pve1 refuses, and a session is short. The media script is the one exception, on purpose (disaster recovery), and only refuses a positive "away".
- **The health check is paused by hand.** What is stored for the container is its ping address, which can report to the check but cannot pause it. Pausing needs a management key of the healthchecks.io project, and a key of that kind can pause or delete every check in the project: a new standing secret, on or next to the container that faces the internet (decision D9). Not taken: `-Home` reminds you instead (backlog B46). Resuming needs no secret: a paused check resumes on the next report, which `-Away` sends, as long as the check keeps its default of resuming on a ping.
- **A pending restart refuses `-Away`.** Windows may restart by itself for an installed update, and a firmware update comes the same way and can clear the TPM, which the sealed Tailscale state depends on: the laptop would be out of the tailnet until it is home (`docs/components/tailscale-client.md`, "TPM"). Pending file renames from installers are reported, not refused: Windows does not restart for them, and most machines have some.
- **The guards are policy, not a wall.** They stop the tooling, not a person with a shell on pve1: SSH to pve1 through the tunnel stays open by design (E15). What they prevent is a real run started from the road by habit.
- **Limits.** Nothing repairs the path from the road: the container does not start with pve1 (`onboot` is off), so a restart of pve1 while away ends the path until you are home. The connection is relayed (D8), so large copies are slow. An away session's disconnect runs from WSL: if WSL is shut down before the session's deadline, the keys go with it but Tailscale stays as it was (backlog B47); `-Home` or `-Disconnect` is the backstop. The 2-hour bound is the session timer's: if the timer dies while WSL runs, the SSH key stays loaded for up to 12 hours (`just session-status` warns). "At home" for `-Away` and `-Home` is the laptop holding one of its reserved addresses: a foreign network that happens to lease 192.168.1.196 or .197 would pass, and `-Home` there would drop the tunnel and open the backup forward, which admits pve1's address only; `-Connect` restores the tunnel.
- **New coupling.** Every guarded recipe now logs in to pve1 once before it starts, at home too: a pve1 that does not answer makes them refuse, and makes a new session short (`HOMELAB_SESSION_HOURS=12 just session-start` at home gives the long one).

## Backup

None. The scripts are in Git; the one state file holds a single fact and is recreated by the next `-Away`.

## Restore

If `travel-state.json` is lost between `-Away` and `-Home`, `-Home` leaves the backup VM as it is and says so: start it by hand if it should run (`Start-VM pbs1`).

## Troubleshooting

| Symptom | Check |
|---|---|
| A real run at home is refused "through the away tunnel" | Tailscale is still connected with the route accepted: `travel.ps1 -Home` (or `-Disconnect`), then run again |
| A guarded recipe is refused because pve1 "did not answer" | pve1, or the SSH key in the session's agent: `just session-status`, `ssh ops@10.0.10.10 true` |
| `-Away`: an operator session is open | `just session-end`, then `-Away` again. The session of a normal terminal is visible to the elevated PowerShell: both reach one WSL (measured at the R.9 gate, 2026-10-16) |
| A play hangs, or is refused, right after `-Home`, `-Connect` or `-Disconnect` | Ansible reuses an SSH connection for 60 seconds, and one opened on the other path stalls: wait a minute, or remove `~/.ansible/cp/*` |
| `just session-status` shows what the timer said | The last session ended at its deadline; a WARNING there means its Tailscale disconnect did not hold: `travel.ps1 -Disconnect` |
| `-Away`: Windows waits for a restart | Restart at home and run `-Away` again |
| `-Away` ends with NOT READY TO TRAVEL after the container started | The failed check names the layer: `docs/components/remote1.md`, "Troubleshooting". Undo with `-Home`, or fix and run `-Away` again (it is safe to repeat) |
| The passphrase prompt does not appear in `-Away` | Run `travel.ps1` in an ordinary elevated PowerShell window, not through a tool that captures its output: the prompt needs the console |
| The health check alerts after `-Home` | It was not paused: pause it in the console. It resumes on the report of the next `-Away` |
| After an away session ended, nothing reaches pve1 | Ending it disconnected Tailscale: `travel.ps1 -Connect`, then `just session-start` |

## Removal

Revert the pull request of R.9: the plays lose their first task, the wrapper and the media script lose their check, the session goes back to 12 hours everywhere. Delete `C:\ProgramData\homelab\travel-state.json` if it exists. Connecting and disconnecting are then done by hand (`docs/components/tailscale-client.md`).
