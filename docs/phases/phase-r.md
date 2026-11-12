# Phase R gate record: remote administration

Status: **steps R.0 to R.10 passed; R.11's documents are merged with this record; one item holds the gate open: the lost-laptop drill (decision D11), which must run before the laptop first travels with the tunnel in earnest.** The plan this record follows is `phase-r-plan.md`; the decision record is `docs/adr/0005-administrative-access.md`. The household part (`phase-r-household-plan.md`) is not built and has its own gate.

## What exists now

The owner can administer the hypervisor from the laptop on mobile data, with the same tools as at home, and from nowhere else. At home nothing changed.

- The laptop and an unprivileged container on pve1 (`remote1`, guest 3010, 10.0.30.10 in VLAN 30) each connect outwards to Tailscale and meet there. Nothing at home listens on the internet.
- Through the container the laptop reaches pve1's SSH and web interface (tcp 22 and 8006) and nothing else. Four layers say so, each from Git: the Tailscale policy, the container's own filter, pve1's filter on the container's network device, and the router's zone `remote`.
- The container runs only between `travel.ps1 -Away` and `-Home`. While away, the tooling refuses real changes to pve1 and allows dry runs.
- Node signing is on, the laptop its only signer. The policy, its tests and the tailnet's settings are code in an OpenTofu root of their own.
- The path is relayed through Tailscale's servers, by decision (D8, and B48 below): about 110 ms and 0.5 MB/s from a phone hotspot.

## Steps

| Step | What | Passed | Pull requests |
|---|---|---|---|
| R.0 | Backups before the phase; rotation of the state passphrase built and rehearsed | 2026-10-09 | 34 |
| R.1 | The OpenTofu roots get the scoped Proxmox token and pve1's CA; `just test-token` | 2026-10-09 | 33 |
| R.2 | The tailnet as code: a policy with no grant, device approval, key expiry 90 days | 2026-10-09 | 35 |
| R.3 | The laptop's client by system policy, its state sealed to the TPM; laptop and phone enrolled; the first grant; the backup port fenced off from the tailnet | 2026-10-11 | 36, 37, 39, 40, 41 |
| R.4 | Node signing on; the way out rehearsed once (disabled with one secret, enabled again), new secrets stored by the owner | 2026-10-11 | 42 |
| R.5 | Router: VLANs 30 and 31, the zone `remote`, rules E15 to E17; `just test-router-zones` 31 of 31 | 2026-10-11 | 44, 45 |
| R.6 | pve1: the bridge carries VLANs 30 and 31, the host firewall admits the container, the pool and the token's paths | 2026-10-11 | 46, 47 |
| R.7 | The container created by OpenTofu, its firewall file by the hypervisor play; 86 checks with each layer alone | 2026-10-12 | 48 |
| R.8 | The container's role: Tailscale in userspace mode as an unprivileged user, its own filter, updates, the health check; the tunnel proven at home, 100 MiB each way | 2026-10-13 | 49 |
| R.9 | Travel mode: `travel.ps1`, the guards that ask pve1 where the session comes from, 2-hour sessions away; `just test-travel` 38 of 38 and one owner-run cycle | 2026-10-16 | 50 |
| R.10 | From outside, and drills 2 to 5: the rebuild at home (Day A, 2026-10-19), the hotspot day (Day B, 2026-11-03) | 2026-11-03, its last test on 2026-11-12 | 51, 52, 53, 55, 67 |
| R.11 | Documents, runbooks, this record | merged with this record; the drill is open | this one |

The figures of each step are in the plan's "Steps" table, which was kept as the running record.

## Tests

| Test | Result |
|---|---|
| `just test-token`: the token reaches its seven paths and no other; creation probes | 38 checks (2026-10-19) |
| `just test-router-zones` | 31 of 31 (2026-10-11) |
| `just test-remote layers`: the allow and deny lists from inside the container, with each layer alone | 145 checks (2026-10-19, after the rebuild) |
| `just test-travel`: the guards, at home with the tunnel forced | 38 of 38 (2026-10-16) |
| `just test-outside`, from a phone hotspot | 75 checks; `web` 3, `phone` 5, `end` 4 (2026-11-03) |
| `just test-fences`: the backup path, after the trip | 23 of 23 (2026-11-12) |
| The phone on the home Wi-Fi, Tailscale off, to the container's addresses | refused at once (2026-11-03) |

## Drills

| # | Drill | Result |
|---|---|---|
| 1 | Lost laptop (D11) | **Not run.** `docs/runbooks/lost-laptop.md`, "The reduced drill" |
| 2 | Rebuild of the container from Git | Done 2026-10-19: 86 minutes, of which 31 the owner's login and signature and 14 a fix; one defect found and fixed (pull request 52) |
| 3 | Outage | Done: the failure report at home on 2026-10-19; from the road on 2026-11-03 the check went down 15 minutes after the container's last report, and the alert reached the owner |
| 4 | Speed | The relayed half done: 109/114/292 ms through the relay; 100 MiB in 198 s down, 230 s up; the dry run of the hypervisor play in 502 s. The UDP half: not run, by decision (B48 below) |
| 5 | Memory | 253 MiB at the peak of a forced update run at home, 225 MiB on the road, against a budget of 297 MiB; the week summed over trips stays open (B49) |

## Defects the phase found and fixed

- A group variable outranked a task's `become: false`, so the guard that reads where the session comes from ran under sudo and would have refused every real run at home (R.9, caught in review).
- The container's own filter cut the first run that loaded it, because the connection carrying the run had no state entry yet (R.8).
- Debian's socket activation made SSH listen on every address of the container (R.8).
- SSH did not survive a cold start of the container: its one address did not exist yet (R.8).
- A purged package's daemon kept running and listening (R.10, pull request 52).
- The provider's plan does not fail on a failing policy test; the wrapper now asks Tailscale's validation first (R.2).
- A false alarm, recorded for honesty: the operator told the owner a TPM clear was pending on the laptop. None was; the firmware answers the question oddly, and the script now asks it differently (R.3, pull request 39).

## Decisions taken during the phase

| Date | Decision |
|---|---|
| 2026-10-09 | Every recommended default, D1 to D12; the household plan approved in principle |
| 2026-10-12 | The token's reach (exception X33): recorded, work goes on with the one token, acted on later (B43) |
| 2026-10-19 | The rebuild drill, the memory week summed over trips, two days for R.10 |
| 2026-11-08 | A check's ping address shown in a screenshot in the operator session: accepted, not rotated |
| 2026-11-12 | **B48: the path stays relayed.** Both readings (home and hotspot) showed that a direct path could form; the owner chose not to open UDP in three layers for speed. A relay of our own on a later cloud server remains the speed fix |

## Exceptions the phase created

X27 (the container's key does not expire), X28 (remote administration depends on Tailscale and GitHub), X29 (no attribution per device, no traffic logs), X32 (the phone can complete the GitHub login) and X33 (the token's reach) are in `docs/ARCHITECTURE.md` section 15. X30 and X31 belong to the household plan and enter the register when it is built. Firewall exceptions E15 to E17 are in section 6.

## Open

| # | Item | Who | Tracked as |
|---|---|---|---|
| 1 | The lost-laptop drill, before the laptop first travels with the tunnel in earnest | Owner with operator, about two hours at home | B30, D11 |
| 2 | The first key renewal, at home, before 2027-01-08; it verifies the renewal runbook | Owner with operator | B58 |
| 3 | The memory week of the container, summed over trips | Operator | B49 |
| 4 | A second, narrower token for the remote-access root | Owner decides | B43, X33 |
| 5 | The health check is paused and resumed by hand around each trip | Owner | B46 |
| 6 | An away session's disconnect depends on WSL running | Operator | B47 |
| 7 | The container's daemon runs with no extra sandboxing beyond its unprivileged user | Operator | noted in `docs/components/remote1.md` |
| 8 | Tailscale is pinned at 1.102.5 on the container; a newer release is a pull request applied at home | Operator | the version pin in `playbooks/group_vars/remote.yaml` |

## What to read

| For | Document |
|---|---|
| Leaving and coming home | `docs/components/travel-mode.md` |
| The container | `docs/components/remote1.md`, `docs/runbooks/rebuild-remote1.md` |
| The laptop's client | `docs/components/tailscale-client.md` |
| The tailnet from nothing | `docs/runbooks/tailnet-setup.md` |
| A lost laptop, a lost phone | `docs/runbooks/lost-laptop.md`, `docs/runbooks/lost-phone.md` |
| An expiring key | `docs/runbooks/renew-tailnet-key.md` |
| The secrets | `docs/security/secrets-register.md` |
