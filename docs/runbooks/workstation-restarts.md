# Workstation: unexpected restarts

The laptop restarts by itself every few days. It holds the backup server VM, so this matters beyond the desk. This runbook records what the logs say and which tests come next. Open item: backlog B54.

## Who this is for

The owner, who runs the tests that need hands on the machine, and the operator, who reads the logs. Report: `powershell -ExecutionPolicy Bypass -File scripts\discovery\node2-restarts.ps1`, read-only, no elevation. Run it after each test and compare.

## What the logs said on 2026-11-03

The System log reached back to 2026-08-25. The owner reports an old fault that happens rarely: sometimes the laptop freezes and is forced off by hand, sometimes it restarts by itself as a PC does in a power cut.

| Restart | Power button seen | Resumes from sleep in that session | Last USB drop before the boot | Last log entry before the boot |
|---|---|---|---|---|
| 09-26 21:08 | yes | 0 | 79 s | 79 s |
| 10-03 21:05 | yes | 0 | 59 s | 60 s |
| 10-09 03:16 | no | 1 | none | 442 s |
| 10-15 19:59 | no | 0 | 43 s | 43 s |
| 10-18 04:46 | no | 1 | none | 149 s |
| 10-21 00:05 | no | 1 | none | 47 s |
| 10-23 20:40 | no | 0 | 45 s | 44 s |
| 10-29 19:23 | no | 0 | 81 s | 79 s |
| 10-30 23:58 | no | 0 | 95 s | 95 s |
| 11-01 02:00 | no | 1 | none | 37 s |

Two kinds separate cleanly, with no overlap:

- **After a USB drop (six).** The dock, its hubs and the USB 2.5 Gb adapter fall off the bus in bursts, then the machine restarts within about 95 seconds. The two with the power button recorded are in this group. A person re-plugging the dock and then forcing a restart would look the same, so the order of events does not prove the dock started it.
- **After a resume from sleep (four).** No USB activity at all. Each happened in a session that had resumed from sleep about 2 to 12 hours earlier, and none of the other six had. Windows also records a different internal marker for these (`Checkpoint` 16 against 0).

The boot's own firmware and start take about 40 seconds of those figures, so at 37 to 47 seconds Windows was running until the reset. Those fit the owner's "like a power cut". The two longest, 149 and 442 seconds, went silent first and fit a freeze.

**Clean:** no processor or bus errors (WHEA), no blue screens or dumps with automatic dumps switched on, no disk or file-system errors, no graphics resets, no thermal warnings, the SSDs report healthy, the battery holds 82 % of its design charge at 174 cycles, and AC power was on before every restart.

**That does not clear the hardware.** A sudden reset, a thermal trip and a loss of power all stop Windows before it can write anything. No record is what those faults look like.

**Worth noting:**

- The two memory modules are different makes (8 GB each, 3200 MHz), and the log holds no memory test.
- The AMD graphics, PSP, GPIO, SMBus and audio co-processor drivers are dated 2020. The dock's DisplayLink driver is dated 2023 and crashed once on 09-07. The USB controller wrote a live report on 10-21 at 01:36.
- All the external USB devices and the camera share one USB controller. The Bluetooth half of the Wi-Fi card is on the other.
- One High Definition Audio controller reports code 43.
- None of the five restarts since the nightly window began fell inside it (02:15 to about 03:30), so the backup VM's disks did not take a reset while running. Nothing protects them if one does; the Sunday verification would show it.

## Tests, in order

One change at a time. At the recent rate of one restart in three days, a clean week is a fair signal and two are firm. Temperatures can run alongside anything.

| # | Test | Who, cost | Reading |
|---|---|---|---|
| 1 | Compare the restart times with pve1's boots (`journalctl --list-boots`) and the router's uptime | Operator, next session, minutes | The same times point at the house's mains. The laptop's battery should still carry it through a dip, so then the charger and battery path come first |
| 2 | Memory: `mdsched.exe`, restart now, F1 for Extended. If restarts go on, MemTest86 from a USB stick overnight | Owner, 1 to 3 hours. A night's backup may be missed; pve1 catches it up | Errors: test each module alone in the first slot, replace the bad one. Clean Extended run does not rule out a rare fault; MemTest86 overnight is the stronger test |
| 3 | Temperatures: HWiNFO, sensors only, logging to a CSV file, left running | Owner, a small install | The last rows before a restart. CPU or GPU near 100 degrees C means cooling: clean the fans, renew the paste |
| 4 | The dock out of the path: a week on the laptop's own charger and screen with the USB 2.5 Gb adapter plugged in directly. If that is too costly, first try the dock through its USB-A adapter in another port | Owner, a week | USB-drop restarts stop: the dock, its cable or the port. They go on without the dock: the laptop |
| 5 | No sleep: a week with the laptop left on or shut down, never asleep | Owner, a week | The resume-kind restarts stop: the resume path, so test 6 next |
| 6 | Drivers: chipset and graphics from the vendor's page for this model, the DisplayLink driver, and the BIOS if a newer one is listed (the installed one is dated 2023-09-20) | Owner, an hour and a restart. Last, because it changes many things at once | Restarts stop: leave it there, the cause does not matter |

If they go on with memory, temperature, dock and drivers cleared, the fault is most likely on the mainboard or in its power regulation, and it is a repair.

To catch the next freeze: Windows can write a crash dump from the keyboard (`CrashOnCtrlScroll` = 1 under `HKLM\SYSTEM\CurrentControlSet\Services\kbdhid\Parameters` and `i8042prt\Parameters`; for a keyboard without Scroll Lock, `Dump1Keys` and `Dump2Key` under the same services' `crashdump` keys). A dump shows what Windows was stuck on; a keyboard that does nothing points below Windows. It needs a restart to take effect and is not set yet.

## The Wi-Fi when docked

Measured the same day, because the owner saw the Wi-Fi turn off.

- **Windows' connection manager**, default setting, no policy (`fMinimizeConnections` absent, `scripts/node2/workstation.ps1` keeps it absent; ARCHITECTURE decision 40). While the dock has connectivity it blocks automatic Wi-Fi connections and may drop a Wi-Fi connection. A connection made by hand is allowed. When the wired link goes it allows them again: 1 second to reconnect on 10-29. This disconnects; it does not switch the radio off. The log is `Microsoft-Windows-Wcmsvc/Operational` id 1015, `Auto enabled: false`.
- **The radio itself** was switched off in software on 2026-11-03, not by airplane mode, and had logged nothing since 11-01 02:21:36, seconds after a dock drop. With the radio off nothing connects by itself, which is what the owner saw. Windows does not log what flips this switch. Switched on again the same day, the card joined the main network in 5 seconds at its reserved address with a strong signal.
- The nightly window's log now shows the radio's state when it finds no home address (`docs/components/pbs.md`).

The main network is set to connect automatically. The old network name is the guest network since Phase 4 and stays manual: a laptop on it has no home address.

## Removal

When the cause is found and a month has passed clean: close B54, keep the finding in the backlog row, delete this runbook and `scripts/discovery/node2-restarts.ps1`.
