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
#            About 40 s is the firmware and the boot alone: Windows was running
#            until the reset. Minutes mean it went silent first: a freeze

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
