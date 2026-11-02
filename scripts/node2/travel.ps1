# Travel mode on the workstation (Node 2, the laptop): the administration
# path through the tunnel while away, the direct path at home. Phase R, step
# R.9: docs/phases/phase-r-plan.md, "Home and away", decisions D5, D7 and D12;
# component docs/components/travel-mode.md.
#
# Run in an elevated PowerShell of the Windows account that uses Tailscale:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\travel.ps1 -Away    before leaving, still at home
#   ... -Home                                                                  back on the home network
#   ... -Connect                                                               the tunnel only: connected, the route accepted
#   ... -Disconnect                                                            the tunnel only: the route dropped, disconnected
# -Connect and -Disconnect need no elevation: they touch the Tailscale client
# only. -Away and -Home shut down and start the backup VM and converge its
# firewall rules, which needs it.
#
# -Away, in order. Every refusal comes before the first change.
#   1. Refuses when: this laptop is not on the home network; an operator
#      session is open (the laptop does not leave with the decrypted key and
#      a loaded SSH key in memory); the backup VM's management window is open;
#      Windows waits for a restart it may start by itself; tailscale.ps1
#      -Check fails; this laptop's node key has expired. Warns when the key
#      expires within two weeks (D7).
#   2. Loads the SSH key into an agent of this run's own (one passphrase;
#      scripts/node2/travel.sh) and checks that pve1 sees this laptop on the
#      direct path. A tunnel that is already up is disconnected first.
#   3. Records whether the backup VM runs, shuts it down, and converges
#      pbs-vm.ps1 -Away (no backup port forward while away) and rdp.ps1 -Off
#      (no Remote Desktop while away; B50).
#   4. Starts the administration container (D12) and connects Tailscale with
#      the route accepted.
#   5. Proves the whole path: the container is online with its tag and its
#      route, pve1 sees this laptop's SSH arrive from the container's address,
#      and the container reports to its health check (which also resumes a
#      check that was paused at home).
# On a failure after a change it leaves the tunnel and the container as they
# are, prints NOT READY TO TRAVEL and exits 1: the owner is at home and can
# look. Undo with -Home, or fix and run -Away again.
#
# -Home: disconnects Tailscale first, so that the next SSH goes direct; adds
# the container's memory on this trip to C:\ProgramData\homelab\
# remote1-memory.log and stops the container; reminds you to pause its health
# check; converges pbs-vm.ps1, which forwards the backup port again and turns
# the backup VM's nightly window back on, and rdp.ps1, which admits the home
# desktop again. It does not start the VM: the
# window does that at night, and a missed night is caught up by pve1 whenever
# the VM next runs (backlog B51).
#
# The health check is paused by hand. What is stored is the address the
# container reports to, and that address can report but cannot pause a check;
# pausing needs a management key of the healthchecks.io project, which this
# design does not hold (decision recorded in docs/components/travel-mode.md).
# Resuming needs nothing: a paused check resumes on the next report, which
# -Away sends.
#
# One fact is kept between the two modes: whether the backup VM ran before
# -Away, in C:\ProgramData\homelab\travel-state.json, written by -Away only if
# it is absent and deleted by -Home. It is not a home or away mode. That is
# never stored: the tooling asks pve1 every time.
#
# Limits, printed by -Away as well: nothing repairs the path from the road.
# The container does not start with pve1, so if pve1 restarts while you are
# away, the path is gone until you are home. The connection is relayed (D8),
# so large copies are slow.

[CmdletBinding()]
param(
    [switch]$Away,
    # -Home. The variable is not $Home: that name is PowerShell's own.
    [Alias('Home')][switch]$AtHome,
    [switch]$Connect,
    [switch]$Disconnect
)

$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }

# ---- settings -------------------------------------------------------------
$Exe = 'C:\Program Files\Tailscale\tailscale.exe'
$VmName = 'pbs1'
$ContainerName = 'remote1'           # its host name in the tailnet
$ContainerTag = 'tag:remote-admin'
$Route = '10.0.10.10/32'             # the one route it advertises: pve1
$TunnelSource = '10.0.30.10'         # the address pve1 sees through the tunnel
# This laptop's two addresses on the home network, the dock and the Wi-Fi,
# both reserved on the router. -Away and -Home run there only.
$HomeAddresses = @('192.168.1.196', '192.168.1.197')
$KeyWarnDays = 14                    # D7
$ManageRule = 'homelab-pbs1-ssh-wsl' # present only while pbs-vm.ps1 -Manage holds the window open
$StateDir = Join-Path $env:ProgramData 'homelab'
$StateFile = Join-Path $StateDir 'travel-state.json'
# One line per trip: the container's memory read by -Home before it stops it
# (drill 5 of the plan; scripts/ops/remote-memory.sh).
$MemoryLog = Join-Path $StateDir 'remote1-memory.log'
# The backup VM's nightly window records each start here (scripts/node2/pbs-night.ps1).
$NightState = Join-Path $env:ProgramFiles 'homelab\pbs-night.json'
$UpSeconds = 90
# ---------------------------------------------------------------------------

$changes = New-Object System.Collections.ArrayList
$problems = New-Object System.Collections.ArrayList
function Step($msg) { [void]$changes.Add($msg); Write-Host "change: $msg" }
function Note($msg) { Write-Host "note:   $msg" }
function Problem($msg) { [void]$problems.Add($msg); Write-Host "NOT OK: $msg" }

function Invoke-Tailscale {
    # The client writes hints to its error stream; under ErrorActionPreference
    # Stop a redirect would turn each line into a throw. The stream is left
    # alone and the exit code is returned (as in tailscale.ps1).
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

function Invoke-TravelVerb {
    # One non-interactive step of travel.sh in WSL. Its lines are shown
    # (unless -Quiet) and it returns the exit code and the last line. A step
    # that asks for a passphrase is not run here: captured, its output would
    # leave WSL without a terminal to ask on.
    param([string]$Verb, [switch]$Quiet)
    $lines = @(& wsl.exe -e bash $TravelSh $Verb)
    $code = $LASTEXITCODE
    if (-not $Quiet) { foreach ($l in $lines) { Write-Host "        $l" } }
    $last = ''
    if ($lines.Count -gt 0) { $last = "$($lines[-1])".Trim() }
    return @{ Code = $code; Last = $last }
}
function Invoke-Sibling {
    # tailscale.ps1 and pbs-vm.ps1 run as child processes, so that their
    # exit code is theirs. An elevated parent gives an elevated child. Their
    # lines go to the console: inside a function, the output of a native
    # command that is not sent anywhere becomes part of the return value, and
    # `-ne 0` would then always hold.
    param([string]$Script, [string[]]$Arguments)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $Script) @Arguments | Out-Host
    return $LASTEXITCODE
}

function Test-HomeAddress {
    $held = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue | Where-Object { $HomeAddresses -contains $_.IPAddress })
    return ($held.Count -gt 0)
}
function Get-RebootReason {
    # Windows restarts by itself for an update it has installed, and a
    # firmware update comes the same way. Away, a restart ends the work in
    # progress, and a firmware update can clear the TPM, which the sealed
    # Tailscale state depends on: the laptop would be out of the tailnet until
    # it is home (docs/components/tailscale-client.md, "TPM"; D5).
    $r = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r += 'Windows Update has installed updates that need a restart' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r += 'component servicing waits for a restart' }
    # A heuristic: no Microsoft reference documents this key. A check that
    # never fires costs nothing; it is kept for an orchestrator that uses it.
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\RebootRequired') { $r += 'the update orchestrator has scheduled a restart' }
    return $r
}
function Get-PendingRenameCount {
    # File replacements an installer left for the next start. Windows does not
    # restart for them by itself, and most machines have some (10 measured on
    # this laptop, 2026-10-15, with every update flag clear): reported, not
    # refused. The value holds pairs: the file, then where it goes.
    $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($null -eq $v) { return 0 }
    return [int][math]::Floor(@($v).Count / 2)
}
function Get-KeyExpiryLine {
    # Read from the client, which reports it while disconnected too. Returns
    # the line for the summary; an expired key is a problem.
    $self = (Get-Json 'status', '--json').Self
    if (-not $self -or -not $self.KeyExpiry) { Note 'the client reports no key expiry for this laptop'; return 'node key: no expiry reported' }
    $raw = $self.KeyExpiry
    if ($raw -is [datetime]) { $exp = $raw.ToUniversalTime() }
    else { $exp = [datetime]::Parse("$raw", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') }
    $days = [int][math]::Floor(($exp - [datetime]::UtcNow).TotalDays)
    $when = $exp.ToString('yyyy-MM-dd')
    if ($days -lt 0) { Problem "this laptop's node key expired on ${when}: renew it at home before travelling (docs/components/tailscale-client.md)" }
    elseif ($days -le $KeyWarnDays) {
        Write-Host ''
        Write-Host "*** This laptop's node key expires on $when, in $days day(s): renew it at home before it lapses on the road (D7). ***"
        Write-Host ''
    }
    return "node key valid until $when ($days days)"
}

function Get-ContainerPeer {
    # A host name need not be unique: an old device left in the tailnet after
    # a rebuild keeps it. The one that is online with its tag and route wins.
    $st = Get-Json 'status', '--json'
    if (-not $st.Peer) { return $null }
    $named = @($st.Peer.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { "$($_.HostName)" -eq $ContainerName })
    $good = @($named | Where-Object { $_.Online -and (@($_.Tags) -contains $ContainerTag) -and (@($_.PrimaryRoutes) -contains $Route) })
    if ($good.Count -gt 0) { return $good[0] }
    if ($named.Count -gt 1) { Note "$($named.Count) devices are named ${ContainerName}: remove the old one in the Tailscale console (docs/runbooks/rebuild-remote1.md, section 3)" }
    if ($named.Count -gt 0) { return $named[0] }
    return $null
}
function Wait-ContainerPeer([int]$Seconds) {
    # Online, carrying its tag, and the primary router for the one route. A
    # container that is not signed never appears here: node signing keeps an
    # unsigned device out of this laptop's view of the tailnet.
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $peer = Get-ContainerPeer
        if ($peer -and $peer.Online -and (@($peer.Tags) -contains $ContainerTag) -and (@($peer.PrimaryRoutes) -contains $Route)) { return $peer }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Connect-Tunnel {
    # The bare forms only. `up` with flags, or --reset, sets every preference
    # it does not name back to its default, and the client's default accepts
    # routes (docs/components/tailscale-client.md). Bare `up` waits for the
    # connection without a limit, so it runs as a process this script ends
    # after $UpSeconds; a --timeout flag would make it an `up` with flags.
    $p = Start-Process -FilePath $Exe -ArgumentList 'up' -NoNewWindow -PassThru
    if (-not $p.WaitForExit($UpSeconds * 1000)) {
        $p.Kill()
        Problem "tailscale up did not finish within $UpSeconds seconds (no internet?)"
    }
    $r = Invoke-Tailscale 'set', '--accept-routes=true'
    if ($r.Code -ne 0) { Problem "tailscale set --accept-routes=true ended with exit code $($r.Code)" }
    # Read back: the client does not refuse an edit by its exit code.
    $backend = $null
    for ($i = 0; $i -lt 15; $i++) {
        $backend = Get-Backend
        if ($backend -eq 'Running') { break }
        Start-Sleep -Seconds 2
    }
    $prefs = Get-Json 'debug', 'prefs'
    if (-not $prefs.WantRunning) { Problem 'the client is not switched on after tailscale up' }
    if (-not $prefs.RouteAll) { Problem 'the client does not accept routes after tailscale set --accept-routes=true' }
    if ($backend -ne 'Running') { Problem "the client is '$backend', not 'Running'" }
    if ($prefs.WantRunning -and $prefs.RouteAll -and $backend -eq 'Running') { Step 'Tailscale connected, the route accepted' }
}
function Disconnect-Tunnel {
    $r = Invoke-Tailscale 'set', '--accept-routes=false'
    if ($r.Code -ne 0) { Problem "tailscale set --accept-routes=false ended with exit code $($r.Code)" }
    $r = Invoke-Tailscale 'down'
    if ($r.Code -ne 0) { Problem "tailscale down ended with exit code $($r.Code)" }
    $prefs = Get-Json 'debug', 'prefs'
    $backend = Get-Backend
    if ($prefs.RouteAll) { Problem 'the client still accepts routes' }
    if ($prefs.WantRunning) { Problem 'the client is still switched on' }
    if ($backend -notin 'Stopped', 'NeedsLogin') { Problem "the client is '$backend' after tailscale down" }
    if (-not $prefs.RouteAll -and -not $prefs.WantRunning) { Step 'Tailscale disconnected, the route no longer accepted' }
}

function Save-BackupVmState {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) { Note "there is no VM $VmName on this laptop"; return 'not present' }
    $running = ($vm.State -eq 'Running')
    if (Test-Path -LiteralPath $StateFile) {
        # A second -Away keeps what the first one saw: the VM is off by now.
        Note "kept the record of an earlier -Away: $((Get-Content -LiteralPath $StateFile -Raw).Trim())"
    }
    else {
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        $json = [pscustomobject]@{ pbs1WasRunning = $running; written = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($StateFile, $json, (New-Object Text.UTF8Encoding($false)))
        Step "recorded that $VmName was $(if ($running) { 'running' } else { 'off' }) before the trip"
    }
    if ($running) {
        # A shutdown through the guest, without a prompt; not a power-off.
        Stop-VM -Name $VmName -Force
        if ((Get-VM -Name $VmName).State -ne 'Off') { throw "$VmName did not shut down" }
        Step "$VmName shut down"
        return 'shut down (it was running)'
    }
    return 'off already'
}
function Restore-BackupVm {
    if (-not (Test-Path -LiteralPath $StateFile)) { Note "no record of a trip: $VmName is left as it is"; return 'left as it is (no record of a trip)' }
    $rec = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($rec.pbs1WasRunning -and -not $vm) {
        # The record is kept, so that a run after the VM is back starts it.
        Problem "the record says $VmName ran before the trip, but there is no VM $VmName"
        return 'absent (it ran before the trip)'
    }
    # Not started here: its nightly window starts it (B51), and a VM started by
    # day runs until it is stopped. pve1 catches up the nights of the trip by
    # itself as soon as the VM runs.
    $result = 'off; it starts with its nightly window at 02:15'
    if ($vm -and $vm.State -eq 'Running') { $result = 'running' }
    elseif ($rec.pbs1WasRunning) {
        Note "$VmName is not started now: its nightly window starts it at 02:15. To catch up the trip's backups at once: Start-VM $VmName (pve1 backs up by itself within five minutes), then Stop-VM $VmName"
    }
    Remove-Item -LiteralPath $StateFile
    Step 'the record of the trip removed'
    return $result
}

# ---- checks before anything changes -----------------------------------------
$modes = @(@($Away.IsPresent, $AtHome.IsPresent, $Connect.IsPresent, $Disconnect.IsPresent) | Where-Object { $_ })
if ($modes.Count -ne 1) { throw 'Name exactly one of -Away, -Home, -Connect and -Disconnect.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Away -or $AtHome) -and -not $elevated) { throw '-Away and -Home shut down and start the backup VM and converge its firewall rules: run this in an elevated PowerShell. (-Connect and -Disconnect need no elevation.)' }
# The client keeps preferences per Windows user and serves one user at a time.
if ($identity.IsSystem) { throw 'Run this as the Windows user who uses Tailscale, not as SYSTEM.' }
$tray = Get-CimInstance Win32_Process -Filter "Name='tailscale-ipn.exe'" | Select-Object -First 1
if ($tray) {
    $traySid = (Invoke-CimMethod -InputObject $tray -MethodName GetOwnerSid).Sid
    if ($traySid -and $traySid -ne $identity.User.Value) { throw "The Tailscale tray application runs as another Windows user ($traySid). Run this script as that user." }
}
if (-not (Test-Path -LiteralPath $Exe)) { throw "Tailscale is not installed at $Exe." }

# ---- -Connect, -Disconnect: the tunnel only -----------------------------------
if ($Connect) {
    # A session opened on the direct path lasts 12 hours and does not take the
    # tunnel with it when it ends; one opened after -Connect is an away
    # session. Asked of WSL on a best-effort basis: a failure says nothing.
    $sh = ("$(& wsl.exe -e wslpath -u (Join-Path $PSScriptRoot 'travel.sh'))").Trim()
    if ($LASTEXITCODE -eq 0 -and $sh) {
        & wsl.exe -e bash $sh session-home | Out-Null
        if ($LASTEXITCODE -eq 0) { Note 'an operator session opened on the direct path is open: it lasts 12 hours and its end does not disconnect Tailscale. For an away session: just session-end, then just session-start after this.' }
    }
    Connect-Tunnel
    if ($problems.Count -eq 0) {
        if (Wait-ContainerPeer 60) { Note "$ContainerName is online and carries the route $Route" }
        else { Problem "$ContainerName is not online with its route ${Route}: is it running? At home, -Away starts it; from the road nothing can." }
    }
}
if ($Disconnect) { Disconnect-Tunnel }

# ---- -Away ------------------------------------------------------------------
$summary = @()
if ($Away) {
    if (-not (Test-HomeAddress)) { throw "-Away runs at home, before leaving: this laptop holds neither of its home addresses ($($HomeAddresses -join ', ')). Away from home, use -Connect. Nothing was changed." }
    $TravelSh = ("$(& wsl.exe -e wslpath -u (Join-Path $PSScriptRoot 'travel.sh'))").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $TravelSh) { throw 'WSL could not translate the path of travel.sh: is the Debian distribution the default one? Nothing was changed.' }
    # 0: a session is open; 1: none. Anything else is WSL failing to answer,
    # which must not pass for "none".
    $session = (Invoke-TravelVerb 'session-open' -Quiet).Code
    if ($session -eq 0) { throw 'An operator session is open: close it first (just session-end), so that the laptop does not leave with the decrypted key and a loaded SSH key in memory. Nothing was changed.' }
    if ($session -ne 1) { throw "Could not tell whether an operator session is open (WSL answered with exit code $session). Nothing was changed." }
    if (Get-NetFirewallRule -Name $ManageRule -ErrorAction SilentlyContinue) { throw "The backup VM's management window is open: close it first with a plain run of pbs-vm.ps1. Nothing was changed." }
    # Shutting the VM down in its nightly window would cut pve1's backup short.
    $night = $null
    if (Test-Path -LiteralPath $NightState) { try { $night = Get-Content -LiteralPath $NightState -Raw | ConvertFrom-Json } catch { $night = $null } }
    $vmNow = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($night -and $vmNow -and $vmNow.State -eq 'Running' -and ((Get-Date) - [datetime]$night.started).TotalHours -lt 5) {
        throw "$VmName is in its nightly window (started at $(([datetime]$night.started).ToString('HH:mm'))): it powers itself off once pve1's backup and its jobs are done. Run -Away after that, or Stop-VM $VmName first to cut the night short. Nothing was changed."
    }
    $reboot = @(Get-RebootReason)
    if ($reboot.Count -gt 0) { throw "Windows waits for a restart ($($reboot -join '; ')). Restart now, at home, and run -Away again: Windows may otherwise restart by itself on the road. Nothing was changed." }
    $renames = Get-PendingRenameCount
    if ($renames -gt 0) { Note "$renames file replacement(s) wait for the next restart (an installer's, not an update's): Windows does not restart for them by itself" }
    if ((Invoke-Sibling 'tailscale.ps1' @('-Check')) -ne 0) { throw 'tailscale.ps1 -Check failed (the lines marked NOT OK above). Nothing was changed.' }
    $keyLine = Get-KeyExpiryLine
    if ($problems.Count -gt 0) { throw "Not travelling: $($problems.Count) check(s) failed (above). Nothing was changed." }

    $ready = $false
    $touched = $false   # set once the backup VM, the forward or the container may have changed
    try {
        if ((Get-Json 'debug', 'prefs').WantRunning) {
            Note 'Tailscale is connected: disconnected first, so that the direct path to pve1 can be checked'
            Disconnect-Tunnel
            if ($problems.Count -gt 0) { throw 'Tailscale was not disconnected cleanly (above): nothing else was changed' }
        }
        Write-Host ''
        # Run here, with this console, so that the passphrase prompt reaches you.
        & wsl.exe -e bash $TravelSh agent-start
        if ($LASTEXITCODE -ne 0) { throw 'the SSH key could not be loaded' }
        $where = (Invoke-TravelVerb 'where' -Quiet).Last
        if ($where -ne 'home') { throw "pve1 does not see this laptop on the direct path (it answers '$where'): -Away runs at home, with pve1 up" }
        Note 'pve1 sees this laptop on the direct path'

        # ---- changes ------------------------------------------------------------
        $touched = $true
        $backupVm = Save-BackupVmState
        if ((Invoke-Sibling 'pbs-vm.ps1' @('-Away')) -ne 0) { throw 'pbs-vm.ps1 -Away failed (above); the backup VM is shut down: a plain run of pbs-vm.ps1 and Start-VM pbs1 undo it' }
        Step 'pbs-vm.ps1 -Away converged: no backup port forward while away'
        # Remote Desktop admits the home desktop only, at home; on the road
        # not even that (owner decision 2026-10-27, B50; exception X34).
        if ((Invoke-Sibling 'rdp.ps1' @('-Off')) -ne 0) { throw 'rdp.ps1 -Off failed (above): Remote Desktop may still be switched on; a plain run of rdp.ps1 at home puts it back' }
        Step 'rdp.ps1 -Off converged: no Remote Desktop while away'
        if ((Invoke-TravelVerb 'container-start').Code -ne 0) { throw 'the container could not be started (above)' }
        Step "$ContainerName runs (D12)"
        Connect-Tunnel
        if ($problems.Count -gt 0) { throw 'Tailscale did not connect as it must (above)' }

        # ---- proof of the whole path -----------------------------------------------
        if (-not (Wait-ContainerPeer 90)) { throw "$ContainerName is not online with its tag and the route $Route within 90 seconds: docs/components/remote1.md, 'Troubleshooting'" }
        Step "$ContainerName is online, tagged, and the router for $Route"
        $where = 'unknown'
        for ($i = 0; $i -lt 10; $i++) {
            $where = (Invoke-TravelVerb 'where' -Quiet).Last
            if ($where -eq 'away') { break }
            Start-Sleep -Seconds 3
        }
        if ($where -ne 'away') { throw "pve1 does not see this laptop arrive through the tunnel (it answers '$where')" }
        Step "pve1 sees this laptop's SSH arrive from ${TunnelSource}: the path goes through the container"
        $health = Invoke-TravelVerb 'health-ping'
        switch ($health.Code) {
            0 { Step 'the container reported to its health check (a paused check resumes on this report)' }
            3 { Note 'the container has no health check: nothing will report this trip (docs/components/remote1.md)' }
            default { Problem "the container's health report failed (exit code $($health.Code)): the check will alert" }
        }
        $ready = ($problems.Count -eq 0)
        if ($ready) {
            $summary = @(
                "AWAY: the tunnel is up with the route accepted; $ContainerName is online and pve1 sees this laptop arrive from $TunnelSource.",
                "  backup VM: $backupVm. The backup port is closed: pve1 has no backup target until -Home, and its dead-man's switch reports the nights it misses. Remote Desktop is off until -Home.",
                '  From now on, also while still at home, real runs against pve1 are refused (pve-apply, tokens, backup init, bootstrap, install media, tofu remote apply); dry runs and plans are allowed.',
                '  A session started now lasts 2 hours, and ending it disconnects Tailscale. To work again after that: travel.ps1 -Connect, then just session-start.',
                '  Limits: nothing repairs this path from the road. If pve1 restarts, the container stays stopped (it does not start with the host) and the path is gone until you are home. Large copies are slow: the connection is relayed (D8).',
                "  $keyLine"
            )
        }
    }
    catch {
        Problem "$($_.Exception.Message)"
    }
    finally {
        [void](Invoke-TravelVerb 'agent-stop' -Quiet)
    }
    if (-not $ready) {
        Write-Host ''
        Write-Host '*** NOT READY TO TRAVEL ***'
        if ($touched) { Write-Host 'The tunnel, the container and the backup VM were left as they are, so that you can look: undo with travel.ps1 -Home, or fix and run -Away again.' }
        elseif ($changes.Count -gt 0) { Write-Host 'Only Tailscale was disconnected; nothing else was changed.' }
        else { Write-Host 'Nothing was changed.' }
    }
}

# ---- -Home ------------------------------------------------------------------
if ($AtHome) {
    if (-not (Test-HomeAddress)) { throw "-Home runs on the home network: this laptop holds neither of its home addresses ($($HomeAddresses -join ', ')). Nothing was changed." }
    $TravelSh = ("$(& wsl.exe -e wslpath -u (Join-Path $PSScriptRoot 'travel.sh'))").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $TravelSh) { throw 'WSL could not translate the path of travel.sh: is the Debian distribution the default one? Nothing was changed.' }
    # First, so that the SSH below goes direct and pve1 stops seeing the tunnel.
    Disconnect-Tunnel
    if ($problems.Count -gt 0) { throw 'Tailscale was not disconnected (above). Nothing else was changed.' }
    $container = 'not stopped'
    try {
        # The operator session's key if one is open, else an agent of this run.
        if ((Invoke-TravelVerb 'key-ready' -Quiet).Code -ne 0) {
            Write-Host ''
            & wsl.exe -e bash $TravelSh agent-start
            if ($LASTEXITCODE -ne 0) { throw 'the SSH key could not be loaded: the container still runs; run -Home again' }
        }
        $where = (Invoke-TravelVerb 'where' -Quiet).Last
        if ($where -ne 'home') { Problem "pve1 sees '$where' after the disconnect, not the direct path" }
        # The trip's memory: read before the stop takes the container's figures
        # with it, written once the stop succeeded, so that a -Home run again
        # after a failed stop does not count the same start twice. A record,
        # not a condition: a failed read or write is only noted.
        $mem = Invoke-TravelVerb 'container-memory' -Quiet
        $record = $null
        if ($mem.Code -eq 0 -and $mem.Last -like 'remote1-memory *') { $record = $mem.Last }
        else { Note "the container's memory was not read ($($mem.Last)): nothing will be added to $MemoryLog" }
        if ((Invoke-TravelVerb 'container-stop').Code -eq 0) {
            Step "$ContainerName stopped (D12)"
            $container = 'stopped'
            if ($record) {
                try {
                    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
                    [IO.File]::AppendAllText($MemoryLog, "$record`r`n", (New-Object Text.UTF8Encoding($false)))
                    Note "the container's memory on this trip, added to ${MemoryLog}: $record"
                }
                catch { Note "the reading was not added to ${MemoryLog} ($($_.Exception.Message)); add it by hand: $record" }
            }
        }
        else { Problem 'the container could not be stopped (above); nothing was added to the memory log: fix it and run -Home again, which reads again' }
    }
    catch {
        Problem "$($_.Exception.Message)"
    }
    finally {
        [void](Invoke-TravelVerb 'agent-stop' -Quiet)
    }
    if ((Invoke-Sibling 'pbs-vm.ps1' @()) -ne 0) { Problem 'pbs-vm.ps1 failed (above): the backup port may still be closed' }
    else { Step 'pbs-vm.ps1 converged: the backup port is forwarded to the VM for pve1 again' }
    if ((Invoke-Sibling 'rdp.ps1' @()) -ne 0) { Problem 'rdp.ps1 failed (above): the home desktop may not reach Remote Desktop; run rdp.ps1 by hand' }
    else { Step 'rdp.ps1 converged: Remote Desktop admits the home desktop again (B50)' }
    # In a try: the reminder below must print whatever happens here.
    try { $backupVm = Restore-BackupVm }
    catch {
        Problem "the backup VM was not restored: $($_.Exception.Message) (the record $StateFile is kept: fix it, then run -Home again, or Start-VM $VmName)"
        $backupVm = 'NOT restored'
    }
    $summary = @(
        "HOME: Tailscale disconnected, the route no longer accepted; $ContainerName $container; backup VM $backupVm.",
        '',
        "*** Pause $ContainerName's health check now, in the healthchecks.io console. It is paused by hand: what is stored can",
        '    report to the check but not pause it. The last report was at most five minutes ago, so the check alerts in',
        '    about ten to fifteen minutes if it is not paused. The report that -Away sends resumes it. ***'
    )
}

# ---- summary ----------------------------------------------------------------
Write-Host ''
foreach ($line in $summary) { Write-Host $line }
if ($changes.Count -eq 0 -and $problems.Count -eq 0) { Write-Host 'Nothing needed changing.' }
if ($problems.Count -gt 0) {
    Write-Host "$($problems.Count) check(s) FAILED: the lines marked NOT OK above."
    exit 1
}
