# Rehearses the away path of the nightly window for real (backlog B51, docs/
# components/pbs.md, "Away from home"): a timer wakes the sleeping laptop, the
# installed pbs-night.ps1 finds no home address for three minutes, logs what it
# saw, and puts the laptop back to sleep. It never starts the VM.
#
# In an elevated PowerShell, at home, after pbs-vm.ps1 has installed the script:
#   powershell -ExecutionPolicy Bypass -File scripts\tests\pbs-night-away.ps1           arm it; prints what to do
#   ... -Result                                                                          read the outcome, remove the task

[CmdletBinding()]
param([switch]$Result, [int]$WakeInMinutes = 5)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated PowerShell.' }

$TaskPath = '\homelab\'
$TaskName = 'pbs1-night-rehearsal'
$Dir = Join-Path $env:ProgramFiles 'homelab'
$NightScript = Join-Path $Dir 'pbs-night.ps1'
$LogFile = Join-Path $Dir 'pbs-night.log'
$Mark = Join-Path $Dir 'pbs-night-rehearsal.txt'

if ($Result) {
    if (-not (Test-Path -LiteralPath $Mark)) { throw "Not armed: no $Mark. Run this without -Result first." }
    $armed = [datetime](Get-Content -LiteralPath $Mark -Raw).Trim()
    $lines = @(Get-Content -LiteralPath $LogFile | Where-Object { $_ -match '^(\S+ \S+) rehearsal: ' -and [datetime]$Matches[1] -ge $armed })
    $lines | ForEach-Object { Write-Host $_ }
    $wake = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $armed } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
    $wake | ForEach-Object { Write-Host "wake at $($_.TimeCreated.ToString('HH:mm:ss')): $((([xml]$_.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'WakeSourceText' } | ForEach-Object { $_.'#text' }))" }
    $checks = @(
        @('the task woke the laptop', [bool]@($wake | Where-Object { $_.ToXml() -match [regex]::Escape($TaskName) }).Count),
        @('it found no home address', [bool]@($lines | Where-Object { $_ -match 'not on the home network after' }).Count),
        @('it said the radio was off', [bool]@($lines | Where-Object { $_ -match 'Wi-Fi radio off' }).Count),
        @('it decided to sleep', [bool]@($lines | Where-Object { $_ -match 'back to sleep' }).Count),
        @('it woke again after the sleep', [bool]@($lines | Where-Object { $_ -match 'awake again' }).Count),
        @('Windows did not refuse', -not @($lines | Where-Object { $_ -match 'refused to sleep' }).Count)
    )
    $failed = 0
    foreach ($c in $checks) {
        Write-Host ("{0}: {1}" -f $(if ($c[1]) { 'PASS' } else { 'FAIL' }), $c[0])
        if (-not $c[1]) { $failed++ }
    }
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Mark -Force
    Write-Host "The rehearsal task is removed. Switch the Wi-Fi back on."
    if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
    Write-Host 'The away path works.'
    exit 0
}

if (-not (Test-Path -LiteralPath $NightScript)) { throw "$NightScript is not installed: run scripts\node2\pbs-vm.ps1 first." }
if ((Get-Content -LiteralPath $NightScript -Raw) -notmatch '\$Rehearse') { throw "$NightScript is an older copy: run scripts\node2\pbs-vm.ps1 first." }
if ($WakeInMinutes -lt 3) { throw 'Give yourself at least 3 minutes to unplug the dock and put the laptop to sleep.' }
$vmState = (Get-VM -Name 'pbs1').State
if ($vmState -ne 'Off') { throw "pbs1 is $vmState: sleeping now would interrupt it. Wait until it is off (the nightly window powers it off from 03:30)." }
$at = (Get-Date).AddMinutes($WakeInMinutes)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$NightScript`" -Rehearse"
$trigger = New-ScheduledTaskTrigger -Once -At $at
$settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'One rehearsal of the nightly window away from home. Removed by scripts/tests/pbs-night-away.ps1 -Result (homelab-infra, B51).' -Force | Out-Null
[IO.File]::WriteAllText($Mark, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Write-Host "Armed: the timer fires at $($at.ToString('HH:mm:ss'))."
Write-Host 'Now, before that time:'
Write-Host '  1. Save your work. Unplug the dock.'
Write-Host '  2. Switch the Wi-Fi off in quick settings (the Wi-Fi button, not airplane mode).'
Write-Host '  3. Start, Power, Sleep.'
Write-Host "It wakes by itself at about $($at.ToString('HH:mm')) and goes back to sleep at about $($at.AddSeconds(200).ToString('HH:mm')). The screen may stay dark."
Write-Host "After $($at.AddMinutes(5).ToString('HH:mm')), wake it with the power button, then run:"
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\tests\pbs-night-away.ps1 -Result"
Write-Host 'A laptop still awake at that time proves nothing, and -Result says so: arm it again.'
