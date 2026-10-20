# The nightly window of the backup server VM (backlog B51; docs/components/
# pbs.md, "Nightly window"). Run by the scheduled task \homelab\pbs1-night as
# SYSTEM at 02:15, and two minutes after Windows starts. scripts\node2\pbs-vm.ps1
# installs it to C:\Program Files\homelab\, which only administrators can
# write; its log and state file live beside it.
#
#   powershell -ExecutionPolicy Bypass -File pbs-night.ps1           as the task runs it
#   ... -DryRun                                                      the checks only, at any time: starts nothing
#
# 1. It exits unless all of these hold: the local time is inside the start
#    window (02:10 to 03:15); this laptop holds one of its home addresses;
#    pbs1 exists and is Off; no install medium is in its drive; its system and
#    datastore disks are attached (a VM in the middle of a rebuild is never
#    started). A VM that runs already was started by someone and is left
#    alone, as is one in any other state.
# 2. It starts pbs1, trying again every 30 seconds for up to 20 minutes (never
#    past 03:15) while Windows cannot give it the memory.
# 3. It waits while pbs1 runs. The VM powers itself off once its jobs are done,
#    from 03:30 (roles/pbs_host, homelab-night-off). At 06:30, if the VM this
#    run started still runs, unrestarted, and the management window is closed,
#    it shuts it down cleanly: never a power-off.
# pve1 does the rest: it backs up at 02:30, tries again until 03:15, and
# catches up a missed night whenever the VM next runs.
#
# scripts\node2\pbs-vm.ps1 changes the VM only while it is off; both scripts
# take the lock Global\homelab-pbs1, so a start never meets a change.

[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

# ---- settings -------------------------------------------------------------
$VmName = 'pbs1'
$HomeAddresses = @('192.168.1.196', '192.168.1.197')
$StartFrom = [timespan]'02:10'
$StartUntil = [timespan]'03:15'
$RetryMinutes = 20
$StopAt = [timespan]'06:30'
$ManageRule = 'homelab-pbs1-ssh-wsl'   # present while the management window is open
$Dir = $PSScriptRoot
$LogFile = Join-Path $Dir 'pbs-night.log'
$StateFile = Join-Path $Dir 'pbs-night.json'
# ---------------------------------------------------------------------------

function Log([string]$msg) {
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

# Keeps Windows from sleeping while this runs; released when the process ends.
Add-Type -Namespace Homelab -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
$EsContinuousSystem = [uint32]'0x80000001'

$mutex = New-Object System.Threading.Mutex($false, 'Global\homelab-pbs1')
function Lock-Vm([int]$Seconds) {
    try { return $mutex.WaitOne([timespan]::FromSeconds($Seconds)) }
    catch [System.Threading.AbandonedMutexException] { return $true }   # its holder died: the lock is ours
}

$today = (Get-Date).Date
$now = Get-Date
$why = $null
if ($now -lt $today.Add($StartFrom) -or $now -ge $today.Add($StartUntil)) { $why = "outside the start window ($StartFrom to $StartUntil)" }
elseif (-not @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue | Where-Object { $HomeAddresses -contains $_.IPAddress }).Count) { $why = "not on the home network (neither $($HomeAddresses -join ' nor '))" }
if ($why -and -not $DryRun) { Log "not starting ${VmName}: $why"; exit 0 }
if ($why) { Log "dry run: would not start: $why (the checks below run anyway)" }

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

    [void][Homelab.Power]::SetThreadExecutionState($EsContinuousSystem)
    $limit = $now.AddMinutes($RetryMinutes)
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
finally { try { $mutex.ReleaseMutex() } catch { } }

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
finally { try { $mutex.ReleaseMutex() } catch { } }
