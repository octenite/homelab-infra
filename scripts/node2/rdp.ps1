# Remote Desktop into the workstation (Node 2) from the home desktop.
# Idempotent: every run converges the listener, its login settings and the
# firewall rules, reads each one back, and prints only what it changed.
#
# Run in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\rdp.ps1          switch on and check
#   ... -Check                                                             check only; changes nothing
#   ... -Off                                                               switch off; the block rules stay
#
# Design: exception X34 in docs/ARCHITECTURE.md (owner decision 2026-10-19);
# component docs/components/remote-desktop.md.
#
# Who is admitted
#   The home desktop only, at 192.168.1.242: a DHCP reservation on the router
#   binds that address to its wired adapter (templates/router-m30/dhcp.j2).
#   The allow rules also name the workstation's two home addresses and the
#   Private profile, which together stand for "at home": Windows starts a
#   network it has not seen before as Public, and a foreign network hands
#   out .196 or .197 only by chance.
#   Block rules turn away every other source, IPv6 included. A block rule
#   wins over an allow rule, so they hold when the Remote Desktop switch in
#   Settings turns the built-in rules back on, which admit every address on
#   every profile. The built-in rules are kept off as well.
#
# The rule names start with rdp-, not homelab-: pbs-vm.ps1 removes every
# homelab-* rule it does not manage itself.

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Off
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }

# ---- settings -------------------------------------------------------------
$Desktop = '192.168.1.242'                          # the home desktop, wired to AP2's access port
$HomeAddresses = @('192.168.1.196', '192.168.1.197') # the workstation's dock port and Wi-Fi adapter
$Port = 3389
$TsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$RdpKey = "$TsKey\WinStations\RDP-Tcp"
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
# Network Level Authentication (the login is checked before a session
# exists) and TLS for the connection: the Windows defaults, held here.
$Values = @(
    @{ Key = $RdpKey; Name = 'UserAuthentication'; Value = 1; What = 'Network Level Authentication on' },
    @{ Key = $RdpKey; Name = 'SecurityLayer'; Value = 2; What = 'TLS for the connection' }
)
# A policy value with one of these names overrides what this script writes,
# without a trace in the keys it reads.
$Overrides = @('fDenyTSConnections', 'UserAuthentication', 'SecurityLayer', 'PortNumber')
# Windows' own rules (names measured on this workstation 2026-10-19: the
# display names are translated, the names are not). Kept off.
$BuiltIn = @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP', 'RemoteDesktop-Shadow-In-TCP', 'RemoteDesktop-In-TCP-WSS')
# Every IPv6 source. The firewall refuses '::/0' (measured 2026-10-19) and
# reads this range back as written.
$AllIpv6 = '::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'
# ---------------------------------------------------------------------------

$changes = New-Object System.Collections.ArrayList
$problems = New-Object System.Collections.ArrayList
function Step($msg) { [void]$changes.Add($msg); Write-Host "change: $msg" }
function Note($msg) { Write-Host "note:   $msg" }
function Problem($msg) { [void]$problems.Add($msg); Write-Host "NOT OK: $msg" }

function ConvertTo-Number([string]$ip) {
    $b = [System.Net.IPAddress]::Parse($ip.Trim()).GetAddressBytes()
    return ([long]$b[0] * 16777216) + ([long]$b[1] * 65536) + ([long]$b[2] * 256) + [long]$b[3]
}
function ConvertFrom-Number([long]$n) {
    return "{0}.{1}.{2}.{3}" -f [math]::Floor($n / 16777216), ([math]::Floor($n / 65536) % 256), ([math]::Floor($n / 256) % 256), ($n % 256)
}
function Get-Value($key, $name) {
    if (-not (Test-Path $key)) { return $null }
    $item = Get-Item $key
    if ($item.GetValueNames() -notcontains $name) { return $null }
    return $item.GetValue($name)
}
function Get-List($list) { (@($list) | ForEach-Object { "$_".Trim() } | Sort-Object) -join ',' }
function Test-Rule($spec) {
    # Windows gives single addresses and ranges back as they were written
    # (measured 2026-10-19), so the lists are compared as text.
    $r = Get-NetFirewallRule -Name $spec.Name -ErrorAction SilentlyContinue
    if (-not $r) { return $false }
    if ("$($r.Enabled)" -ne 'True' -or "$($r.Direction)" -ne 'Inbound' -or "$($r.Action)" -ne $spec.Action -or "$($r.Profile)" -ne $spec.Profile) { return $false }
    $pf = $r | Get-NetFirewallPortFilter
    if ("$($pf.Protocol)" -ne $spec.Protocol -or (@($pf.LocalPort) -join ',') -ne "$Port") { return $false }
    $af = $r | Get-NetFirewallAddressFilter
    if ((Get-List $af.LocalAddress) -ne (Get-List $spec.Local) -or (Get-List $af.RemoteAddress) -ne (Get-List $spec.Remote)) { return $false }
    if ((@(($r | Get-NetFirewallInterfaceFilter).InterfaceAlias) -join ',') -ne 'Any') { return $false }
    if ("$(($r | Get-NetFirewallApplicationFilter).Program)" -ne 'Any') { return $false }
    if ("$(($r | Get-NetFirewallServiceFilter).Service)" -ne 'Any') { return $false }
    return $true
}
function Set-Rule($spec) {
    if (Test-Rule $spec) { return }
    if ($Check) { Problem "firewall rule $($spec.Name) is missing or differs: $($spec.Display)"; return }
    Get-NetFirewallRule -Name $spec.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $spec.Name -DisplayName $spec.Display -Description 'Managed by scripts/node2/rdp.ps1 (homelab-infra)' `
        -Direction Inbound -Action $spec.Action -Profile $spec.Profile -Protocol $spec.Protocol -LocalPort $Port `
        -LocalAddress $spec.Local -RemoteAddress $spec.Remote | Out-Null
    # Read back: the fence is only as good as the rule that really exists.
    if (-not (Test-Rule $spec)) { throw "firewall rule $($spec.Name) is not in place after creating it" }
    Step "firewall: $($spec.Display)"
}
function Get-Listener {
    $tcp = [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    $udp = [bool](Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)
    return @{ Tcp = $tcp; Udp = $udp }
}

# ---- checks before anything changes -----------------------------------------
if ($Check -and $Off) { throw '-Check and -Off cannot be combined.' }
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this in an elevated PowerShell.' }
foreach ($n in $Overrides) {
    if ($null -ne (Get-Value $PolicyKey $n)) { throw "$PolicyKey holds the value '$n', which overrides what this script sets. Nothing was changed. Find out who wrote it, remove it, and run again." }
}
$portNow = Get-Value $RdpKey 'PortNumber'
if ($portNow -ne $Port) { throw "Remote Desktop listens on port $portNow, not $Port. Nothing was changed: the rules below name $Port." }
$others = @(
    "0.0.0.0-$(ConvertFrom-Number ((ConvertTo-Number $Desktop) - 1))",
    "$(ConvertFrom-Number ((ConvertTo-Number $Desktop) + 1))-255.255.255.255",
    $AllIpv6
)

# ---- listener and login settings ------------------------------------------------
$deny = if ($Off) { 1 } else { 0 }
if ((Get-Value $TsKey 'fDenyTSConnections') -ne $deny) {
    $want = if ($Off) { 'off' } else { 'on' }
    if ($Check) { Problem 'Remote Desktop is switched off' }
    else {
        Set-ItemProperty -Path $TsKey -Name fDenyTSConnections -Value $deny -Type DWord
        if ((Get-Value $TsKey 'fDenyTSConnections') -ne $deny) { throw 'fDenyTSConnections is not in place after writing it' }
        Step "Remote Desktop switched $want"
    }
}
foreach ($v in $Values) {
    if ((Get-Value $v.Key $v.Name) -eq $v.Value) { continue }
    if ($Check) { Problem "$($v.Name) is not $($v.Value) ($($v.What))"; continue }
    Set-ItemProperty -Path $v.Key -Name $v.Name -Value $v.Value -Type DWord
    if ((Get-Value $v.Key $v.Name) -ne $v.Value) { throw "$($v.Name) is not in place after writing it" }
    Step "$($v.Name) = $($v.Value): $($v.What)"
}
# The service has no start trigger and starts on demand (measured
# 2026-10-19). It is started here; -Off leaves it running, because stopping
# it ends a session, and with the listener switched off it admits nobody.
$svc = Get-Service TermService
if (-not $Off -and $svc.Status -ne 'Running') {
    if ($Check) { Problem 'the Remote Desktop service (TermService) is not running' }
    else {
        Start-Service TermService
        Step 'Remote Desktop service (TermService) started'
    }
}

# ---- firewall ---------------------------------------------------------------------
foreach ($name in $BuiltIn) {
    $r = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if (-not $r -or "$($r.Enabled)" -ne 'True') { continue }
    if ($Check) { Problem "the built-in rule $name is on: it admits every address on every profile (the block rules still hold)"; continue }
    Disable-NetFirewallRule -Name $name
    Step "firewall: built-in rule $name off"
}
$rules = @()
foreach ($proto in 'TCP', 'UDP') {
    $p = $proto.ToLower()
    $rules += @{ Name = "rdp-others-$p"; Display = "rdp: $proto $Port from nobody but the desktop"; Action = 'Block'; Profile = 'Any'; Protocol = $proto; Local = @('Any'); Remote = $others }
    if (-not $Off) {
        $rules += @{ Name = "rdp-desktop-$p"; Display = "rdp: $proto $Port from the desktop $Desktop, at home (X34)"; Action = 'Allow'; Profile = 'Private'; Protocol = $proto; Local = $HomeAddresses; Remote = @($Desktop) }
    }
}
foreach ($r in $rules) { Set-Rule $r }
foreach ($r in @(Get-NetFirewallRule -Name 'rdp-*' -ErrorAction SilentlyContinue)) {
    if (@($rules | ForEach-Object { $_.Name }) -contains $r.Name) { continue }
    if ($Check) { Problem "firewall rule $($r.Name) is not one this script wants"; continue }
    Remove-NetFirewallRule -Name $r.Name
    Step "firewall: rule removed: $($r.Name)"
}

# ---- what is really there ------------------------------------------------------------
$listen = $null
for ($i = 0; $i -lt 10; $i++) {
    # The service opens and closes its listener a moment after the switch.
    $listen = Get-Listener
    if ($Off -or ($listen.Tcp -and $listen.Udp)) { break }
    Start-Sleep -Seconds 1
}
if (-not $Off) {
    if (-not $listen.Tcp) { Problem "nothing listens on TCP $Port" }
    if (-not $listen.Udp) { Note "nothing listens on UDP $Port; connections fall back to TCP" }
    foreach ($a in $HomeAddresses) {
        $ip = Get-NetIPAddress -IPAddress $a -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ip) { continue }
        $prof = Get-NetConnectionProfile -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue
        if ("$($prof.NetworkCategory)" -ne 'Private') { Note "$a on '$($ip.InterfaceAlias)' is on the network '$($prof.Name)', which Windows treats as $($prof.NetworkCategory): the desktop is not admitted over it" }
    }
    $setting = Get-CimInstance -Namespace root\cimv2\TerminalServices -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
    if ($setting.SSLCertificateSHA1Hash) { Write-Host "certificate thumbprint (compare it at the desktop's first connection): $($setting.SSLCertificateSHA1Hash)" }
}
elseif ($listen.Tcp) { Note "TCP $Port still listens; with no allow rule the block rules turn every source away" }

# ---- summary ----------------------------------------------------------------
Write-Host ''
$state = if ((Get-Value $TsKey 'fDenyTSConnections') -eq 0) { 'on' } else { 'off' }
Write-Host "Remote Desktop $state; listening: TCP $($listen.Tcp), UDP $($listen.Udp); admitted: $(if ($state -eq 'on' -and -not $Off) { "$Desktop to $($HomeAddresses -join ' and ') on a Private network" } else { 'nobody' })"
if ($changes.Count -eq 0 -and $problems.Count -eq 0) { Write-Host 'Remote Desktop matches the script. Nothing was changed.' }
elseif ($changes.Count -gt 0) { Write-Host "$($changes.Count) change(s)." }
if ($problems.Count -gt 0) {
    Write-Host "$($problems.Count) check(s) FAILED: the lines marked NOT OK above."
    exit 1
}
