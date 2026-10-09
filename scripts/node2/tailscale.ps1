# Tailscale client on the workstation (Node 2). Idempotent: every run converges
# the client's system policies and checks what the client really holds, and
# prints only what it changed. It never connects the laptop to the tailnet.
#
# Run in an elevated PowerShell of the Windows account that uses Tailscale:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\tailscale.ps1          converge and check
#   ... -Check                                                                   check only; changes nothing
#   ... -Enrol                                                                   the one login of this laptop, then disconnect
#
# Design: docs/adr/0005-administrative-access.md, decision D5 of
# docs/phases/phase-r-plan.md; component docs/components/tailscale-client.md.
#
# Why system policies and not `tailscale set`
#   A preference set with `tailscale set` belongs to one login profile and
#   can be changed back by a click in the tray menu. A policy under
#   HKLM\SOFTWARE\Policies\Tailscale is read by the service for every
#   profile, needs an administrator to change, and puts a forced preference
#   back whenever something edits it. The client does not refuse such an
#   edit: `tailscale set --shields-up=false` ends with exit code 0 and the
#   value stays. So this script never trusts an exit code; it reads back.
#
# What is forced, and what is left alone
#   Forced: no inbound connection (shields up), no name service from
#   Tailscale, no unattended mode, no automatic update and no update check,
#   no exit node offered, no posture reporting, the update item hidden in the
#   tray menu (the update policies do not stop an update started by hand
#   there), and the node state sealed with the TPM (D5).
#   Left alone: accepting subnet routes. travel.ps1 switches it on for a trip
#   and off at home, which a forced policy would silently undo.
#   Refused when found: policies that connect by themselves, choose an exit
#   node, carry a key or point to another server.
#
# State encryption fails open in the client (read in its source at 1.102.4):
#   with the policy set and the TPM not usable, the service keeps the plain
#   file without an error; with the policy value missing or of the wrong type
#   at a later start, it turns the sealed file back into a plain one. The
#   policy value and the shape of the file are therefore checked on every
#   run, and -Enrol refuses to log in while the file is not sealed.
#   The seal binds the file to this TPM and to nothing else. It stops a copy
#   of the disk; it does not stop someone who starts this laptop (X23).
#
# The version is pinned by assertion: no policy can pin it. An update is a
# pull request that changes $Version and $InstallerSha256 here.

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Enrol
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }

# ---- settings -------------------------------------------------------------
$Version = '1.102.4'   # the newest Windows build of the 1.102 line; 1.102.5 exists for Linux only
$InstallerSha256 = '80EB007E39DFEBE17299FA1A09C79A8E1D934F76E0246C0817EBE3AF675B7EF6'   # tailscale-setup-1.102.4-amd64.msi
$Exe = 'C:\Program Files\Tailscale\tailscale.exe'
$StateDir = 'C:\ProgramData\Tailscale'
$StateFile = "$StateDir\server-state.conf"
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Tailscale'
$LegacyKey = 'HKLM:\SOFTWARE\Tailscale IPN'
# Strings are case-sensitive in the client: anything but exactly these
# spellings is read as "the user decides", without an error.
$Policies = @(
    @{ Name = 'AllowIncomingConnections'; Kind = 'String'; Value = 'never'; What = 'no inbound connection (shields up)' },
    @{ Name = 'UseTailscaleDNSSettings'; Kind = 'String'; Value = 'never'; What = 'no name service from Tailscale' },
    @{ Name = 'UnattendedMode'; Kind = 'String'; Value = 'never'; What = 'no unattended mode' },
    @{ Name = 'InstallUpdates'; Kind = 'String'; Value = 'never'; What = 'no automatic update' },
    @{ Name = 'CheckUpdates'; Kind = 'String'; Value = 'never'; What = 'no update check' },
    @{ Name = 'AdvertiseExitNode'; Kind = 'String'; Value = 'never'; What = 'never an exit node' },
    @{ Name = 'PostureChecking'; Kind = 'String'; Value = 'never'; What = 'no posture reporting' },
    @{ Name = 'UpdateMenu'; Kind = 'String'; Value = 'hide'; What = 'update item hidden in the tray menu' },
    @{ Name = 'EncryptState'; Kind = 'DWord'; Value = 1; What = 'node state sealed with the TPM (D5)' }
)
# Never wanted, in either key: each connects by itself, picks an exit node,
# carries a key, names another server, or takes the route switch away.
$Forbidden = @('UseTailscaleSubnets', 'AlwaysOn.Enabled', 'AlwaysOn.OverrideWithReason', 'ReconnectAfter', 'ExitNodeID', 'ExitNodeIP', 'AuthKey', 'LoginURL', 'Tailnet', 'HardwareAttestation')
# ---------------------------------------------------------------------------

$changes = New-Object System.Collections.ArrayList
$problems = New-Object System.Collections.ArrayList
function Step($msg) { [void]$changes.Add($msg); Write-Host "change: $msg" }
function Note($msg) { Write-Host "note:   $msg" }
function Problem($msg) { [void]$problems.Add($msg); Write-Host "NOT OK: $msg" }

function Invoke-Tailscale {
    # The client writes hints and the login address to its error stream;
    # under ErrorActionPreference Stop a redirect would turn each line into
    # a throw. The stream is left alone and the exit code is returned.
    param([string[]]$Arguments)
    $out = & $Exe @Arguments
    return @{ Out = ($out -join "`n"); Code = $LASTEXITCODE }
}
function Get-Json([string[]]$Arguments) {
    $r = Invoke-Tailscale $Arguments
    if (-not $r.Out) { throw "tailscale $($Arguments -join ' ') printed nothing (exit code $($r.Code))" }
    return $r.Out | ConvertFrom-Json
}
function Get-Backend { (Get-Json 'status', '--json').BackendState }
function Get-PolicyValue($key, $name) {
    # Value names may contain a dot ("AlwaysOn.Enabled"), so the registry
    # object is asked, not the property syntax.
    if (-not (Test-Path $key)) { return $null }
    $item = Get-Item $key
    if ($item.GetValueNames() -notcontains $name) { return $null }
    return @{ Kind = "$($item.GetValueKind($name))"; Value = $item.GetValue($name) }
}
function Test-Policy($p) {
    if ($p -is [string]) { $p = $Policies | Where-Object { $_.Name -eq $p } }
    $have = Get-PolicyValue $PolicyKey $p.Name
    return ($have -and $have.Kind -eq $p.Kind -and "$($have.Value)" -ceq "$($p.Value)")
}
function Get-StateShape {
    # sealed: one JSON object with exactly the members data, key and nonce.
    # plain:  any other JSON object, "{}" before the first login.
    if (-not (Test-Path -LiteralPath $StateFile)) { return 'absent' }
    $raw = [IO.File]::ReadAllText($StateFile)
    if (-not $raw.Trim()) { return 'empty' }
    try { $j = $raw | ConvertFrom-Json } catch { return 'unreadable' }
    $names = (@($j.PSObject.Properties.Name) | Sort-Object) -join ','
    if ($names -ceq 'data,key,nonce') { return 'sealed' }
    return 'plain'
}
function Get-TpmBlocker {
    # A reason not to seal anything with this TPM now, or nothing.
    $t = Get-Tpm
    if (-not ($t.TpmPresent -and $t.TpmReady -and $t.TpmEnabled)) { return 'the TPM is not present, enabled and ready' }
    if ($t.LockedOut) { return 'the TPM is locked out' }
    $w = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm
    if ("$($w.SpecVersion)" -notmatch '^2\.0') { return "the TPM is version '$($w.SpecVersion)', not 2.0" }
    $pending = ($w | Invoke-CimMethod -MethodName GetPhysicalPresenceRequest).Request
    if ($pending -ne 0) {
        return "the firmware holds a pending TPM operation (request $pending; 5, 14, 21 and 22 clear the TPM at the next start). A cleared TPM cannot open a sealed state: the laptop would have to be enrolled again. See docs/components/tailscale-client.md, 'TPM'"
    }
    return $null
}
function Wait-Service {
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        try { if (Get-Backend) { return } } catch { continue }
    }
    throw 'the Tailscale service did not answer within 60 seconds after its restart'
}

# ---- checks before anything changes -----------------------------------------
if ($Check -and $Enrol) { throw '-Check and -Enrol cannot be combined.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this in an elevated PowerShell.' }
# The client keeps preferences per Windows user and serves one user at a
# time. Run as another account, every command would read and change a
# different, empty profile, or be refused.
if ($identity.IsSystem) { throw 'Run this as the Windows user who uses Tailscale, not as SYSTEM.' }
$tray = Get-CimInstance Win32_Process -Filter "Name='tailscale-ipn.exe'" | Select-Object -First 1
if ($tray) {
    $traySid = (Invoke-CimMethod -InputObject $tray -MethodName GetOwnerSid).Sid
    if ($traySid -and $traySid -ne $identity.User.Value) { throw "The Tailscale tray application runs as another Windows user ($traySid). Run this script as that user." }
}
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "Tailscale is not installed at $Exe. Install tailscale-setup-$Version-amd64.msi from https://pkgs.tailscale.com/stable/ (SHA-256 $InstallerSha256), then run this again."
}
$have = ((Invoke-Tailscale 'version').Out -split "`n")[0].Trim()
if ($have -ne $Version) { throw "Tailscale $have is installed; this script pins $Version. Install the pinned version, or change the pin by pull request." }
if (-not (Get-Service Tailscale -ErrorAction SilentlyContinue)) { throw 'The Tailscale service does not exist.' }
# Two other places can override the registry policies without a trace in it.
foreach ($f in "$StateDir\syspolicy.json", "$StateDir\tailscaled-env.txt") {
    if (Test-Path -LiteralPath $f) { throw "$f exists. It overrides what this script sets; find out who wrote it before going on." }
}
foreach ($k in $PolicyKey, $LegacyKey) {
    foreach ($n in $Forbidden) {
        if (Get-PolicyValue $k $n) { throw "$k holds the value '$n', which this design never sets. Nothing was changed. Find out who wrote it, remove it, and run again." }
    }
}
if (Test-Path $PolicyKey) {
    $unknown = @((Get-Item $PolicyKey).GetValueNames() | Where-Object { $_ -and (@($Policies | ForEach-Object { $_.Name }) -notcontains $_) })
    if ($unknown.Count -gt 0) { throw "$PolicyKey holds values this script does not know: $($unknown -join ', '). Nothing was changed." }
}
$leftovers = @(Get-ChildItem -LiteralPath $StateDir -Filter 'server-state.conf.tmp*' -Force -ErrorAction SilentlyContinue)
if ($leftovers.Count -gt 0) { throw "Left-over state copies in ${StateDir}: $($leftovers.Name -join ', '). Each may hold the node's keys. Nothing was changed." }
$shapeBefore = Get-StateShape
if ($shapeBefore -in 'empty', 'unreadable') { throw "$StateFile is $shapeBefore. Nothing was changed: the client cannot convert such a file." }
$backendBefore = Get-Backend

# ---- policies ---------------------------------------------------------------
$tpmBlocker = Get-TpmBlocker
$restart = $false
foreach ($p in $Policies) {
    if (Test-Policy $p) { continue }
    if ($Check) { Problem "policy $($p.Name) is not $($p.Value) ($($p.What))"; continue }
    if ($p.Name -eq 'EncryptState') {
        # Never sealed with a TPM that is about to be cleared, and never
        # switched on under a running connection.
        if ($tpmBlocker) { continue }
        if ($backendBefore -notin 'NeedsLogin', 'Stopped', 'NoState') { Problem "state encryption is not switched on while the client is $backendBefore; disconnect first (tailscale down)"; continue }
    }
    if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey | Out-Null }
    New-ItemProperty -Path $PolicyKey -Name $p.Name -PropertyType $p.Kind -Value $p.Value -Force | Out-Null
    if (-not (Test-Policy $p)) { throw "policy $($p.Name) is not in place after writing it" }
    Step "policy $($p.Name) = $($p.Value): $($p.What)"
    $restart = $true
}
$encryptWanted = Test-Policy 'EncryptState'
if (-not $Check -and -not $restart -and $encryptWanted -and (Get-StateShape) -eq 'plain' -and $backendBefore -in 'NeedsLogin', 'Stopped', 'NoState') {
    # The policy is set and the file is plain: the service converts it at
    # its next start, if it can use the TPM.
    $restart = $true
}
if ($restart) {
    # The service reads its policies when it starts. A reload from a user's
    # shell reloads the user's view, not the one the service works with.
    Restart-Service Tailscale
    Wait-Service
    Step 'Tailscale service restarted (it reads the policies and converts the state file at its start)'
}

# ---- what the client really holds ---------------------------------------------
$shape = Get-StateShape
if ($encryptWanted) {
    if ($shape -ne 'sealed') { Problem "state encryption is switched on but $StateFile is $shape. The service could not use the TPM, or did not read the policy. Do not log in" }
}
elseif ($tpmBlocker) { Problem "state encryption is NOT switched on: $tpmBlocker" }
$status = Get-Json 'status', '--json'
foreach ($h in @($status.Health)) {
    if ("$h" -match 'State store') { Problem "the service reports: $h" }
}
$seen = $null
try { $seen = (Get-Json 'syspolicy', 'list', '--json').Settings } catch { Note 'the client lists no policy settings' }
foreach ($p in $Policies) {
    if (-not (Test-Policy $p)) { continue }   # reported above
    $s = if ($seen) { $seen.PSObject.Properties | Where-Object Name -eq $p.Name | Select-Object -First 1 }
    $want = if ($p.Kind -eq 'DWord') { 'True' } else { "$($p.Value)" }
    if (-not $s) { Problem "the client does not list the policy $($p.Name)" }
    elseif ($s.Value.Error) { Problem "the client reports an error for the policy $($p.Name): $($s.Value.Error)" }
    elseif ("$($s.Value.Value)" -cne $want) { Problem "the client reads the policy $($p.Name) as '$($s.Value.Value)', not '$want'" }
}
$prefs = Get-Json 'debug', 'prefs'
function Test-Pref($name, $actual, $wanted) {
    if ("$actual" -ne "$wanted") { Problem "preference ${name} is '$actual', expected '$wanted'" }
}
if (Test-Policy 'AllowIncomingConnections') { Test-Pref 'ShieldsUp' $prefs.ShieldsUp $true }
if (Test-Policy 'UseTailscaleDNSSettings') { Test-Pref 'CorpDNS (name service from Tailscale)' $prefs.CorpDNS $false }
if (Test-Policy 'UnattendedMode') { Test-Pref 'ForceDaemon (unattended mode)' ([bool]$prefs.ForceDaemon) $false }
if (Test-Policy 'CheckUpdates') { Test-Pref 'AutoUpdate.Check' $prefs.AutoUpdate.Check $false }
if ($prefs.AutoUpdate.Apply -eq $true) { Problem 'preference AutoUpdate.Apply is true' }
Test-Pref 'RunSSH' $prefs.RunSSH $false
Test-Pref 'AdvertiseRoutes' "$($prefs.AdvertiseRoutes)" ''
Test-Pref 'ExitNodeID' "$($prefs.ExitNodeID)" ''
if ($prefs.WantRunning -and -not $Enrol) { Note "the client is switched on (backend: $($status.BackendState)). This script leaves that alone; travel.ps1 owns it." }

# ---- the one login ------------------------------------------------------------
if ($Enrol) {
    if ($problems.Count -gt 0) { throw "Not logging in: $($problems.Count) check(s) above failed." }
    if (-not $encryptWanted -or $shape -ne 'sealed') { throw 'Not logging in: the node state is not sealed.' }
    if ($status.BackendState -ne 'NeedsLogin') { throw "Not logging in: the client is '$($status.BackendState)', not 'NeedsLogin'. This laptop is enrolled already, or a login is pending. Every login creates a new device." }
    Write-Host ''
    Write-Host 'A browser address follows. Open it on THIS laptop and sign in with GitHub.'
    Write-Host 'The laptop is on the tailnet from the end of that login until this script disconnects it;'
    Write-Host 'the policy in Git grants it nothing, and the policies above are in force.'
    Write-Host ''
    # Every setting is named: a login starts a new profile, and what is not
    # forced by a policy would start from the client's defaults, which
    # accept routes.
    $login = Invoke-Tailscale 'login', '--shields-up', '--accept-dns=false', '--accept-routes=false', '--unattended=false', '--timeout=5m'
    # Disconnect in every case: a login that timed out stays pending with
    # the connection wanted.
    $down = Invoke-Tailscale 'down'
    if ($login.Code -ne 0) { throw "tailscale login ended with exit code $($login.Code). The client was told to disconnect (exit code $($down.Code)). Read the state with -Check before trying again." }
    Step 'logged in once and disconnected'
    $set = Invoke-Tailscale 'set', '--accept-routes=false', '--auto-update=false'
    if ($set.Code -ne 0) { Problem "tailscale set ended with exit code $($set.Code)" }
    $prefs = Get-Json 'debug', 'prefs'
    $status = Get-Json 'status', '--json'
    Test-Pref 'WantRunning' $prefs.WantRunning $false
    Test-Pref 'LoggedOut' $prefs.LoggedOut $false
    Test-Pref 'RouteAll (accept routes)' $prefs.RouteAll $false
    Test-Pref 'ShieldsUp' $prefs.ShieldsUp $true
    Test-Pref 'CorpDNS' $prefs.CorpDNS $false
    Test-Pref 'AutoUpdate.Apply' $prefs.AutoUpdate.Apply $false
    if ($status.BackendState -ne 'Stopped') { Problem "the client is '$($status.BackendState)' after the login, expected 'Stopped'" }
    if ((Get-StateShape) -ne 'sealed') { Problem "$StateFile is no longer sealed after the login: treat the node key as written to the disk in the clear" }
    Write-Host ''
    Write-Host "This laptop's addresses in the tailnet (the policy in Git names the first):"
    Write-Host (@($status.Self.TailscaleIPs) -join ', ')
    Write-Host 'It waits for approval in the Tailscale console (Machines). Approve it there.'
}

# ---- summary ----------------------------------------------------------------
Write-Host ''
if ($changes.Count -eq 0 -and $problems.Count -eq 0) { Write-Host 'The Tailscale client matches the script. Nothing was changed.' }
elseif ($changes.Count -gt 0) { Write-Host "$($changes.Count) change(s)." }
Write-Host "version $have; backend $($status.BackendState); state file $(Get-StateShape); accept routes: $($prefs.RouteAll); switched on: $($prefs.WantRunning)"
if ($problems.Count -gt 0) {
    Write-Host "$($problems.Count) check(s) FAILED: the lines marked NOT OK above."
    exit 1
}
