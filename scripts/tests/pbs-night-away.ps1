# Rehearses the nightly window for real (backlog B51, docs/components/pbs.md,
# "Away from home"): a timer wakes the sleeping laptop on battery, and the
# installed pbs-night.ps1 does what it would do at 02:15, except that it never
# starts the VM. It takes a laptop with the dock unplugged and the Wi-Fi radio off.
#
# In an elevated PowerShell, at home, after pbs-vm.ps1 has installed the script:
#   powershell -ExecutionPolicy Bypass -File scripts\tests\pbs-night-away.ps1     the home Wi-Fi in range: it switches the radio on, joins and finds the home address; the laptop stays awake
#   ... -NoHomeWifi                                                               as away from home: it finds nothing, puts the radio back off and goes back to sleep
#   ... -Result                                                                   read the outcome, remove the task

[CmdletBinding()]
param([switch]$Result, [switch]$NoHomeWifi, [int]$WakeInMinutes = 5)

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
$WifiHomeAddress = '192.168.1.197'

if ($Result) {
    if (-not (Test-Path -LiteralPath $Mark)) { throw "Not armed: no $Mark. Run this without -Result first." }
    $marked = @(Get-Content -LiteralPath $Mark)
    $armed = [datetime]$marked[0]
    $wasNoHomeWifi = $marked[1] -eq 'NoHomeWifi'
    $lines = @(Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(\S+ \S+) rehearsal: ' -and [datetime]$Matches[1] -ge $armed })
    $lines | ForEach-Object { Write-Host $_ }
    $wake = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $armed } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
    $wake | ForEach-Object { Write-Host "wake at $($_.TimeCreated.ToString('HH:mm:ss')): $((([xml]$_.ToXml()).Event.EventData.Data | Where-Object { $_.Name -eq 'WakeSourceText' } | ForEach-Object { $_.'#text' }))" }
    $radioOffNow = ((& netsh.exe wlan show interfaces) -join "`n") -match 'Software\s+Off'

    $failed = 0
    function Test-Line([string]$Pattern) { return [bool]@($lines | Where-Object { $_ -match $Pattern }).Count }
    function Report([string]$Name, [bool]$Ok) {
        Write-Host ("{0}: {1}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name)
        if (-not $Ok) { $script:failed++ }
    }
    Report 'the task woke the laptop' ([bool]@($wake | Where-Object { $_.ToXml() -match [regex]::Escape($TaskName) }).Count)
    Report 'it ran on battery' (Test-Line 'on battery')
    Report 'it switched the radio on, as SYSTEM' (Test-Line 'switched it on')
    if ($wasNoHomeWifi) {
        Report 'it found no home address' (Test-Line 'not on the home network after')
        Report 'it put the radio back off' ((Test-Line 'back off, as it was') -and $radioOffNow)
        Report 'it decided to sleep' (Test-Line 'back to sleep')
        Report 'Windows did not refuse' (-not (Test-Line 'refused to sleep'))
        Report 'the laptop really slept: a second wake followed the timer''s' ($wake.Count -ge 2)
        Report 'the sleep call held until that wake' (Test-Line 'returned [1-9]\d* minutes later')
    }
    else {
        Report "it joined the home Wi-Fi and found $WifiHomeAddress" (Test-Line "found $([regex]::Escape($WifiHomeAddress)) after")
        Report 'it did not go back to sleep' (-not (Test-Line 'back to sleep'))
        Report 'the radio is on now' (-not $radioOffNow)
    }
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Mark -Force
    Write-Host 'The rehearsal task is removed.'
    if ($wasNoHomeWifi) { Write-Host 'Switch the home Wi-Fi''s automatic connection back on, and the Wi-Fi.' }
    if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
    if ($wasNoHomeWifi) { Write-Host 'The away path works.' }
    else { Write-Host 'The radio path works. On a real night this is where pbs1 starts and pve1 backs up over Wi-Fi.' }
    exit 0
}

if (-not (Test-Path -LiteralPath $NightScript)) { throw "$NightScript is not installed: run scripts\node2\pbs-vm.ps1 first." }
if ((Get-Content -LiteralPath $NightScript -Raw) -notmatch 'Enable-WifiRadio') { throw "$NightScript is an older copy: run scripts\node2\pbs-vm.ps1 first." }
if ($WakeInMinutes -lt 3) { throw 'Give yourself at least 3 minutes to unplug the dock and put the laptop to sleep.' }
$vmState = (Get-VM -Name 'pbs1').State
if ($vmState -ne 'Off') { throw "pbs1 is ${vmState}: sleeping now would interrupt it. Wait until it is off (the nightly window powers it off from 03:30)." }
$at = (Get-Date).AddMinutes($WakeInMinutes)
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$NightScript`" -Rehearse"
$trigger = New-ScheduledTaskTrigger -Once -At $at
$settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 5)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'One rehearsal of the nightly window. Removed by scripts/tests/pbs-night-away.ps1 -Result (homelab-infra, B51).' -Force | Out-Null
[IO.File]::WriteAllLines($Mark, @((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $(if ($NoHomeWifi) { 'NoHomeWifi' } else { 'HomeWifi' })))
Write-Host "Armed: the timer fires at $($at.ToString('HH:mm:ss'))."
Write-Host 'Now, before that time:'
Write-Host '  - Save your work. Unplug the dock and the charger: the battery is the case this proves.'
if ($NoHomeWifi) { Write-Host '  - Settings, Network & internet, Wi-Fi, Manage known networks, your main network: switch off "Connect automatically when in range".' }
Write-Host '  - Switch the Wi-Fi off in quick settings (the Wi-Fi button, not airplane mode).'
Write-Host '  - Start, Power, Sleep.'
if ($NoHomeWifi) {
    Write-Host "It wakes by itself at about $($at.ToString('HH:mm')), switches the Wi-Fi on, finds nothing, switches it off and goes back to sleep at about $($at.AddSeconds(200).ToString('HH:mm')). The screen may light up. Do not touch it until then."
    Write-Host "After $($at.AddMinutes(5).ToString('HH:mm')), wake it with the power button, then run:"
}
else {
    Write-Host "It wakes by itself at about $($at.ToString('HH:mm')), switches the Wi-Fi on and joins the home network. It stays awake. The screen may light up. Do not touch it until $($at.AddMinutes(4).ToString('HH:mm'))."
    Write-Host 'Then open it and run:'
}
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\tests\pbs-night-away.ps1 -Result"
Write-Host 'A laptop still awake at that time proves nothing, and -Result says so: arm it again.'
