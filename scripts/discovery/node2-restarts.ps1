# The workstation's unexpected restarts, from Windows' own logs (backlog B54,
# docs/runbooks/workstation-restarts.md). Read-only; needs no elevation. Run it
# after each test in the runbook and compare.
#   powershell -ExecutionPolicy Bypass -File scripts\discovery\node2-restarts.ps1
#
# One row per restart (Kernel-Power 41):
#   button   Windows saw the power button first: a forced restart
#   resumes  resumes from sleep in the session that ended (Windows' own counter)
#   usb      seconds before the new boot that the last USB device fell off the
#            bus, if one fell in the 10 minutes before
#   quiet    seconds between the last entry of the main logs and the new boot.
#            The firmware and the start of the boot take under 11 s (measured on
#            the restart of 2026-11-03). More than that is a stretch with no entry,
#            which may be a freeze or only a quiet log: logs are not a heartbeat
# Then the crash rate before and after a resume, the restarts by fortnight, and
# the hardware errors recorded.

$ErrorActionPreference = 'SilentlyContinue'
$logs = 'System', 'Application', 'Microsoft-Windows-WLAN-AutoConfig/Operational', 'Microsoft-Windows-Wcmsvc/Operational',
    'Microsoft-Windows-NetworkProfile/Operational', 'Microsoft-Windows-TaskScheduler/Operational',
    'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational', 'Microsoft-Windows-PushNotification-Platform/Operational',
    'Microsoft-Windows-Application-Experience/Program-Telemetry', 'Windows PowerShell'

$removed = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Device Management'; Id = 1010 } | Where-Object { $_.Message -match 'Device USB\\' } | ForEach-Object { $_.TimeCreated })
$restarts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } | Sort-Object TimeCreated)
"System log reaches back to $((Get-WinEvent -LogName System -MaxEvents 1 -Oldest).TimeCreated.ToString('yyyy-MM-dd'))"
"{0,-17} {1,-7} {2,-8} {3,-8} {4}" -f 'restart', 'button', 'resumes', 'usb', 'quiet'
foreach ($r in $restarts) {
    $d = @{}
    ([xml]$r.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }
    $bootEvent = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12; StartTime = $r.TimeCreated.AddMinutes(-5); EndTime = $r.TimeCreated.AddMinutes(1) } | Select-Object -First 1
    $boot = if ($bootEvent) { $bootEvent.TimeCreated } else { $r.TimeCreated }
    $usb = @($removed | Where-Object { $_ -lt $boot -and $_ -ge $boot.AddMinutes(-10) } | Sort-Object)
    $last = foreach ($l in $logs) { Get-WinEvent -FilterHashtable @{ LogName = $l; StartTime = $boot.AddHours(-6); EndTime = $boot.AddSeconds(-1) } -MaxEvents 1 }
    $newest = $last | Sort-Object TimeCreated -Descending | Select-Object -First 1
    "{0,-17} {1,-7} {2,-8} {3,-8} {4}" -f $r.TimeCreated.ToString('yyyy-MM-dd HH:mm'),
        $(if ($d['PowerButtonTimestamp'] -ne '0') { 'yes' } else { '-' }),
        $d['SystemSleepTransitionsToOn'],
        $(if ($usb.Count) { "$([int]($boot - $usb[-1]).TotalSeconds) s" } else { '-' }),
        $(if ($newest) { "$([int]($boot - $newest.TimeCreated).TotalSeconds) s" } else { '?' })
}

$boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12 } | Sort-Object TimeCreated | ForEach-Object { $_.TimeCreated })
$downs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 13 } | Sort-Object TimeCreated | ForEach-Object { $_.TimeCreated })
$wakes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } | ForEach-Object {
        $f = @{}
        ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $f[$_.Name] = $_.'#text' }
        [pscustomobject]@{ Sleep = [datetime]$f['SleepTime']; Wake = [datetime]$f['WakeTime'] }
    } | Sort-Object Wake)
$hoursBefore = 0.0; $hoursAfter = 0.0; $crashesBefore = 0; $crashesAfter = 0
for ($i = 0; $i -lt $boots.Count; $i++) {
    $boot = $boots[$i]
    $next = if ($i + 1 -lt $boots.Count) { $boots[$i + 1] } else { $null }
    $crashed = $next -and @($restarts | Where-Object { $_.TimeCreated -ge $next.AddMinutes(-1) -and $_.TimeCreated -lt $next.AddMinutes(5) }).Count
    $down = @($downs | Where-Object { $_ -gt $boot -and (-not $next -or $_ -lt $next) } | Select-Object -Last 1)
    $end = if (-not $next) { Get-Date } elseif ($crashed -or -not $down.Count) { $next } else { $down[0] }
    $resumed = @($wakes | Where-Object { $_.Wake -gt $boot -and $_.Wake -lt $end })
    if ($resumed.Count) {
        $hoursBefore += ($resumed[0].Sleep - $boot).TotalHours
        $hoursAfter += ($end - $resumed[0].Wake).TotalHours
        for ($j = 1; $j -lt $resumed.Count; $j++) { $hoursAfter -= ($resumed[$j].Wake - $resumed[$j].Sleep).TotalHours }
        if ($crashed) { $crashesAfter++ }
    }
    else {
        $hoursBefore += ($end - $boot).TotalHours
        if ($crashed) { $crashesBefore++ }
    }
}
"`nCrash rate, hours awake with the sleep left out"
"  before any sleep in that session: {0:N0} h, {1} restarts{2}" -f $hoursBefore, $crashesBefore, $(if ($crashesBefore) { ", one per {0:N0} h" -f ($hoursBefore / $crashesBefore) })
"  after a resume in that session:   {0:N0} h, {1} restarts{2}" -f $hoursAfter, $crashesAfter, $(if ($crashesAfter) { ", one per {0:N0} h" -f ($hoursAfter / $crashesAfter) })

"`nBy fortnight, from the first boot in the log"
$from = $boots[0].Date
while ($from -lt (Get-Date)) {
    $to = $from.AddDays(14)
    "  {0}: {1,3} boots, {2} restarts" -f $from.ToString('MM-dd'), @($boots | Where-Object { $_ -ge $from -and $_ -lt $to }).Count, @($restarts | Where-Object { $_.TimeCreated -ge $from -and $_.TimeCreated -lt $to }).Count
    $from = $to
}

"`nHardware errors Windows recorded, over the same logs (all should read 0)"
$counts = [ordered]@{
    'processor or bus errors (WHEA-Logger)' = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' }).Count
    'processor or bus errors (Kernel-WHEA)' = @(Get-WinEvent -LogName 'Microsoft-Windows-Kernel-WHEA/Errors' -MaxEvents 200).Count
    'blue screens'                          = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 }).Count
    'crash dumps'                           = @(Get-ChildItem 'C:\Windows\Minidump').Count + [int](Test-Path 'C:\Windows\MEMORY.DMP')
    'disk or file system errors'            = @(foreach ($p in 'disk', 'stornvme', 'storahci', 'Ntfs', 'Microsoft-Windows-Ntfs', 'Microsoft-Windows-StorPort') { Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $p; Level = 1, 2, 3 } }).Count
    'graphics driver resets'                = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101 }).Count
    'thermal shutdown warnings'             = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 86, 88, 125 }).Count
}
foreach ($k in $counts.Keys) { "  {0,-40} {1}" -f $k, $counts[$k] }

"`nMemory test results (Windows Memory Diagnostic; 1201 is clean, 1202 found errors)"
$m = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 5)
if ($m.Count) { $m | ForEach-Object { "  {0} id {1}" -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $_.Id } } else { '  none in this log' }

"`nThe parts"
Get-CimInstance Win32_PhysicalMemory | ForEach-Object { "  memory {0} GB {1} MHz, part {2}" -f [int]($_.Capacity / 1GB), $_.ConfiguredClockSpeed, ($_.PartNumber -replace '\s+$', '') }
Get-PhysicalDisk | ForEach-Object { "  disk {0} GB, {1}, {2}" -f [int]($_.Size / 1GB), $_.HealthStatus, $_.OperationalStatus }
Get-CimInstance Win32_VideoController | ForEach-Object { "  graphics {0}, driver dated {1}" -f $_.Name, $_.DriverDate.ToString('yyyy-MM-dd') }
Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } | ForEach-Object { "  problem device: {0} (code {1})" -f $_.Name, $_.ConfigManagerErrorCode }
$report = Join-Path $env:TEMP 'node2-battery.xml'
powercfg /batteryreport /xml /output $report | Out-Null
if (Test-Path $report) {
    $battery = ([xml](Get-Content $report)).BatteryReport.Batteries.Battery
    "  battery holds {0} % of its design charge, {1} cycles" -f [int](100 * [double]$battery.FullChargeCapacity / [double]$battery.DesignCapacity), $battery.CycleCount
    Remove-Item $report -Force
}
$wlan = (netsh wlan show interfaces) -join "`n"
"  Wi-Fi radio: $(if ($wlan -match 'Software\s+(On|Off)') { $Matches[1] } else { 'on, joined' })"
