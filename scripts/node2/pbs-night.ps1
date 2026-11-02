# The nightly window of the backup server VM (backlog B51; docs/components/
# pbs.md, "Nightly window"). Run by the scheduled task \homelab\pbs1-night as
# SYSTEM at 02:15, and two minutes after Windows starts. scripts\node2\pbs-vm.ps1
# installs it to C:\Program Files\homelab\, which only administrators can
# write; its log and state file live beside it.
#
#   powershell -ExecutionPolicy Bypass -File pbs-night.ps1           as the task runs it
#   ... -DryRun                                                      the checks only, at any time: starts nothing, never sleeps
#   ... -Rehearse                                                    the away path, at any time: never starts the VM (scripts\tests\pbs-night-away.ps1)
#
# 1. It exits unless the local time is inside the start window (02:10 to 03:15).
# 2. It looks for one of this laptop's home addresses, for up to 3 minutes: after
#    a wake the dock or the Wi-Fi need a moment. With none it logs what it saw
#    and starts nothing. If this task's own timer woke the laptop, it then puts
#    the laptop back to sleep, so that it does not stay awake in a bag (owner
#    decision 2026-11-03). Sleep and not a shutdown, because open work survives
#    it; hibernation is off on this laptop (exception X23). A laptop that was
#    awake anyway is left on.
# 3. It exits unless pbs1 exists and is Off; no install medium is in its drive;
#    its system and datastore disks are attached (a VM in the middle of a
#    rebuild is never started). A VM that runs already was started by someone
#    and is left alone, as is one in any other state.
# 4. It starts pbs1, trying again every 30 seconds for up to 20 minutes (never
#    past 03:15) while Windows cannot give it the memory.
# 5. It waits while pbs1 runs. The VM powers itself off once its jobs are done,
#    from 03:30 (roles/pbs_host, homelab-night-off). At 06:30, if the VM this
#    run started still runs, unrestarted, and the management window is closed,
#    it shuts it down cleanly: never a power-off.
# pve1 does the rest: it backs up at 02:30, tries again until 03:15, and
# catches up a missed night whenever the VM next runs.
#
# scripts\node2\pbs-vm.ps1 changes the VM only while it is off; both scripts
# take the lock Global\homelab-pbs1, so a start never meets a change.

[CmdletBinding()]
param([switch]$DryRun, [switch]$Rehearse)

$ErrorActionPreference = 'Stop'

# ---- settings -------------------------------------------------------------
$VmName = 'pbs1'
$HomeAddresses = @('192.168.1.196', '192.168.1.197')
$StartFrom = [timespan]'02:10'
$StartUntil = [timespan]'03:15'
$HomeLookSeconds = 180       # two of Windows' one-minute Wi-Fi scans, and the dock's return after a wake
$HomeLookEvery = 10
$WakeSource = 'homelab\pbs1-night'   # the power log names the task whose timer woke the laptop; the rehearsal's name starts the same
$WakeRecentMinutes = 10      # an older wake by this task was not this run's
$RetryMinutes = 20
$StopAt = [timespan]'06:30'
$ManageRule = 'homelab-pbs1-ssh-wsl'   # present while the management window is open
$Dir = $PSScriptRoot
$LogFile = Join-Path $Dir 'pbs-night.log'
$StateFile = Join-Path $Dir 'pbs-night.json'
# ---------------------------------------------------------------------------

function Log([string]$msg) {
    if ($Rehearse) { $msg = "rehearsal: $msg" }
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    if ($DryRun) { Write-Host $line; return }
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 512KB) {
            $keep = Get-Content -LiteralPath $LogFile -Tail 2000
            [IO.File]::WriteAllLines($LogFile, $keep)
        }
        [IO.File]::AppendAllText($LogFile, "$line`r`n")
    }
    catch { Write-Host $line }
}

function Get-AvailableMB {
    try { return [int](Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch { return -1 }
}

function Test-AtHome {
    return [bool]@(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue | Where-Object { $HomeAddresses -contains $_.IPAddress }).Count
}

function Test-InWindow {
    $time = (Get-Date).TimeOfDay
    return $time -ge $StartFrom -and $time -lt $StartUntil
}

# What the links looked like. The next morning's reader must be able to tell
# "away from home" from "at home with the Wi-Fi radio off".
function Get-LinkFact {
    $facts = @()
    try {
        $facts += @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.InterfaceDescription -notmatch 'Bluetooth' } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Status)" })
        $wlan = (& netsh.exe wlan show interfaces) -join "`n"
        if ($wlan -match 'Software\s+(On|Off)') { $facts += "Wi-Fi radio $($Matches[1].ToLower())" }
        if ($wlan -match '(?m)^\s*SSID\s*:\s*(.+?)\s*$') { $facts += "joined to $($Matches[1])" }
        $battery = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
        # BatteryStatus: 1 discharging, 4 low, 5 critical; the other values are on AC.
        if ($battery) { $facts += "$(if ($battery.BatteryStatus -in 1, 4, 5) { 'on battery' } else { 'on AC' }) at $($battery.EstimatedChargeRemaining) %" }
    }
    catch { $facts += "unread: $(($_.Exception.Message -split "`n")[0])" }
    return $facts -join ', '
}

# The time of the latest wake, if this task's timer caused it, it is recent, and
# Windows has not restarted since (a boot adds no wake record, so the timer's
# would still read as the newest). The power log names the task: "Windows will
# execute 'NT TASK\homelab\pbs1-night' scheduled task that requested waking the
# computer."
function Get-TaskWake {
    try {
        $last = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 1 -ErrorAction Stop
        $source = ([xml]$last.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'WakeSourceText' } | ForEach-Object { $_.'#text' }
        $booted = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if ("$source" -like "*$WakeSource*" -and ((Get-Date) - $last.TimeCreated).TotalMinutes -le $WakeRecentMinutes -and $last.TimeCreated -gt $booted) { return $last.TimeCreated }
    }
    catch { Log "the power log could not be read: $(($_.Exception.Message -split "`n")[0])" }
    return $null
}

# SetThreadExecutionState keeps Windows from sleeping while this runs, until the
# process ends. RtlAdjustPrivilege turns on the shutdown privilege that SYSTEM
# holds switched off, which a sleep needs. rundll32 cannot make this call: its
# arguments arrive as garbage and can disable the wake timers the next night needs.
Add-Type -Namespace Homelab -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
[DllImport("kernel32.dll")] public static extern bool IsSystemResumeAutomatic();
[DllImport("ntdll.dll")] public static extern int RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool previous);
[DllImport("powrprof.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.I1)] public static extern bool SetSuspendState([MarshalAs(UnmanagedType.I1)] bool hibernate, [MarshalAs(UnmanagedType.I1)] bool force, [MarshalAs(UnmanagedType.I1)] bool wakeEventsDisabled);
'@
$EsContinuous = [uint32]'0x80000000'
$EsContinuousSystem = [uint32]'0x80000001'
$SeShutdownPrivilege = 19

# Back to sleep, if this task's timer is what woke the laptop. Anyone who touched
# it in these few minutes wakes it again with a key; their work is still there.
# Windows' answer to "has a person been active since the wake" is logged and
# gates nothing yet: PowerToys Awake keeps the display required on this laptop,
# which may read as a person, and a wrong answer would leave it awake in a bag.
# The call returns when the laptop wakes, and this run then ends at once, ahead
# of the next night's 02:15.
function Suspend-Laptop {
    $woke = Get-TaskWake
    if (-not $woke) { Log 'this task did not wake the laptop: it stays on'; return }
    Log "this task woke the laptop at $($woke.ToString('HH:mm:ss')) and it holds no home address: back to sleep (Windows calls the wake automatic: $([Homelab.Power]::IsSystemResumeAutomatic()))"
    [void][Homelab.Power]::SetThreadExecutionState($EsContinuous)
    $previous = $false
    [void][Homelab.Power]::RtlAdjustPrivilege($SeShutdownPrivilege, $true, $false, [ref]$previous)
    $asleep = Get-Date
    if ([Homelab.Power]::SetSuspendState($false, $false, $false)) { Log "the sleep call returned $([int]((Get-Date) - $asleep).TotalMinutes) minutes later" }
    else { Log "Windows refused to sleep (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())): the laptop stays on"; exit 1 }
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\homelab-pbs1')
function Lock-Vm([int]$Seconds) {
    try { return $mutex.WaitOne([timespan]::FromSeconds($Seconds)) }
    catch [System.Threading.AbandonedMutexException] { return $true }   # its holder died: the lock is ours
}

$why = $null
$away = $false
if (-not $Rehearse -and -not (Test-InWindow)) { $why = "outside the start window ($StartFrom to $StartUntil)" }
else {
    # Held from here on: Windows sleeps again 2 minutes after a timer wake unless
    # something holds it, which is shorter than the look. It does not stop the
    # explicit sleep of Suspend-Laptop, which releases it first anyway.
    if (-not $DryRun) { [void][Homelab.Power]::SetThreadExecutionState($EsContinuousSystem) }
    $lookUntil = (Get-Date).AddSeconds($HomeLookSeconds)
    $atHome = Test-AtHome
    while (-not $atHome -and -not $DryRun -and (Get-Date) -lt $lookUntil) {
        Start-Sleep -Seconds $HomeLookEvery
        $atHome = Test-AtHome
    }
    if (-not $atHome) {
        $away = $true
        $looked = if ($DryRun) { 'at this one look' } else { "after $HomeLookSeconds s" }
        $why = "not on the home network $looked (neither $($HomeAddresses -join ' nor '); $(Get-LinkFact))"
    }
    elseif (-not $Rehearse -and -not (Test-InWindow)) { $why = "the start window ($StartFrom to $StartUntil) ended during the look" }
}
if ($why -and -not $DryRun) {
    Log "not starting ${VmName}: $why"
    if ($away) { Suspend-Laptop }
    exit 0
}
if ($why) { Log "dry run: would not start: $why (the checks below run anyway)" }
if ($away) { Log "dry run: a real run looks for $HomeLookSeconds s first, then $(if (Get-TaskWake) { 'puts the laptop back to sleep: this task woke it' } else { 'leaves the laptop on: this task did not wake it' })" }
if ($Rehearse) {
    if (-not $away) { Log 'a home address is held, so there is nothing to rehearse: unplug the dock and switch the Wi-Fi off' }
    exit 0
}

if (-not (Lock-Vm 60)) { Log "not starting ${VmName}: pbs-vm.ps1 holds the lock"; exit 0 }
try {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    $refuse = $null
    if (-not $vm) { $refuse = "there is no VM $VmName" }
    elseif ($vm.State -eq 'Running') { $refuse = "$VmName runs already: someone started it, it is left alone" }
    elseif ($vm.State -ne 'Off') { $refuse = "$VmName is $($vm.State), not Off: left alone" }
    else {
        $dvd = @(Get-VMDvdDrive -VMName $VmName | Where-Object { $_.Path })
        $disks = @(Get-VMHardDiskDrive -VMName $VmName | ForEach-Object { Split-Path -Leaf $_.Path })
        if ($dvd.Count) { $refuse = "an install medium is in the drive ($($dvd[0].Path)): a rebuild is in progress" }
        elseif ($disks -notcontains 'system.vhdx' -or $disks -notcontains 'datastore.vhdx') { $refuse = "the disks attached are '$($disks -join ', ')', not the system and datastore disks: a rebuild is in progress" }
        else {
            # An empty system disk (after -WipeSystem, before the install) holds no system to start.
            $sys = Get-VMHardDiskDrive -VMName $VmName | Where-Object { (Split-Path -Leaf $_.Path) -eq 'system.vhdx' } | Select-Object -First 1
            if ((Get-VHD -Path $sys.Path).FileSize -lt 1GB) { $refuse = 'the system disk is empty: a rebuild is in progress' }
        }
    }
    if ($refuse) { Log "not starting: $refuse"; exit 0 }
    if ($DryRun -or $why) { Log "dry run: every check passed for the VM; $(if ($why) { 'the time or place did not' } else { 'it would start now' })"; exit 0 }

    $today = (Get-Date).Date
    $limit = (Get-Date).AddMinutes($RetryMinutes)
    if ($limit -gt $today.Add($StartUntil)) { $limit = $today.Add($StartUntil) }
    $started = $null
    while ($true) {
        try {
            Start-VM -Name $VmName -ErrorAction Stop
            $started = Get-Date
            break
        }
        catch {
            $msg = ($_.Exception.Message -split "`n")[0]
            Log "start failed: $msg (Windows has $(Get-AvailableMB) MiB available)"
        }
        if ((Get-VM -Name $VmName).State -eq 'Running') { Log "$VmName runs now, started by someone else"; exit 0 }
        if ((Get-Date).AddSeconds(30) -ge $limit) { break }
        Start-Sleep -Seconds 30
    }
    if (-not $started) { Log "gave up starting $VmName at $(Get-Date -Format 'HH:mm'): pve1's backup misses this night unless the VM is started later"; exit 1 }
    $vmId = (Get-VM -Name $VmName).Id.Guid
    $state = [pscustomobject]@{ started = $started.ToString('o'); vmId = $vmId } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($StateFile, $state)
    Log "started $VmName (Windows had $(Get-AvailableMB) MiB available after the start)"
}
finally { try { $mutex.ReleaseMutex() } catch { $null = $_ } }

# ---- while it runs --------------------------------------------------------
$stopAt = $today.Add($StopAt)
while ((Get-Date) -lt $stopAt) {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -eq 'Off') { Log "$VmName is off ($([int]((Get-Date) - $started).TotalMinutes) minutes after the start)"; exit 0 }
    Start-Sleep -Seconds 60
}

# ---- the backstop -----------------------------------------------------------
if (-not (Lock-Vm 300)) { Log "06:30 backstop skipped: pbs-vm.ps1 holds the lock"; exit 0 }
try {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm -or $vm.State -ne 'Running') { Log "06:30: $VmName is $(if ($vm) { $vm.State } else { 'gone' })"; exit 0 }
    $ranSince = ((Get-Date) - $started).TotalSeconds
    if ($vm.Id.Guid -ne $vmId -or $vm.Uptime.TotalSeconds -lt ($ranSince - 300)) { Log "06:30: $VmName was restarted since this run started it: left running"; exit 0 }
    if (Get-NetFirewallRule -Name $ManageRule -ErrorAction SilentlyContinue) { Log "06:30: the management window is open: $VmName left running"; exit 0 }
    Log "06:30: $VmName still runs; shutting it down (its jobs did not let it power itself off: see its journal, homelab-night-off)"
    Stop-VM -Name $VmName -Force   # a shutdown through the guest, not a power-off
    Log "06:30: $VmName is $((Get-VM -Name $VmName).State)"
}
finally { try { $mutex.ReleaseMutex() } catch { $null = $_ } }
