# Workstation (Node 2) policy. Idempotent; prints only what it changed.
# Run in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\workstation.ps1
#
# The dock port and the Wi-Fi adapter hold two different reserved addresses
# (decision reversed 2026-10-06: one shared address deadlocked Windows, which
# refused the dock's lease while Wi-Fi held the address and would only drop
# Wi-Fi once the dock had connectivity). Both links may be up at once, so no
# connection-manager policy is set; one set earlier is removed here.
#
# It also keeps Windows on one service per process, and keeps the operator
# session's key out of the page file, WSL's swap and the hibernation file
# (owner decisions 2026-10-07; exceptions X23 and X25 in docs/ARCHITECTURE.md).

$ErrorActionPreference = 'Stop'
$changes = 0

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated PowerShell.' }

$key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy'
if ((Get-ItemProperty -Path $key -Name fMinimizeConnections -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty -Path $key -Name fMinimizeConnections
    Write-Host 'change: connection-manager policy removed; wired and Wi-Fi may be up together'
    $changes++
}

# The USB 2.5 GbE adapter carries the direct link to the hypervisor. Windows
# may power it down when it sees no traffic, which drops the link (seen
# 2026-10-06: link up at 2.5 Gbit/s for 37 s, then down). Power management
# off for it, whenever it is plugged in.
$p2pAdapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object InterfaceDescription -match 'USB 2.5GbE|UE302|Realtek PCIe GbE'
foreach ($p2p in $p2pAdapters) {
    $pm = Get-NetAdapterPowerManagement -Name $p2p.Name
    if ($pm.AllowComputerToTurnOffDevice -ne 'Disabled' -or $pm.SelectiveSuspend -ne 'Disabled' -or $pm.DeviceSleepOnDisconnect -ne 'Disabled') {
        Disable-NetAdapterPowerManagement -Name $p2p.Name -NoRestart
        Set-NetAdapterPowerManagement -Name $p2p.Name -SelectiveSuspend Disabled -DeviceSleepOnDisconnect Disabled -ErrorAction SilentlyContinue
        Write-Host "change: power management off on '$($p2p.Name)' (direct link adapter)"
        $changes++
    }
}
if (-not $p2pAdapters) { Write-Host 'note:   no direct-link adapter present; power settings are applied on a run with one plugged in' }

$reboot = $false

# ---- one service per process (owner decision 2026-10-07) ------------------------
# Windows gives each service its own process when the machine has more memory
# than this threshold. On this machine it had been raised above the installed
# memory, so many services shared one process, and a built-in firewall rule
# scoped to one of those services admitted the ports of all of them: the
# forwarded backup and management ports answered every source (found by the
# deny test of 2026-10-06). The Windows default is restored; the block rules
# of pbs-vm.ps1 stay as the second layer.
$splitDefault = 3670016
$control = 'HKLM:\SYSTEM\CurrentControlSet\Control'
$splitNow = (Get-ItemProperty -Path $control -Name SvcHostSplitThresholdInKB -ErrorAction SilentlyContinue).SvcHostSplitThresholdInKB
if ($splitNow -ne $splitDefault) {
    Set-ItemProperty -Path $control -Name SvcHostSplitThresholdInKB -Value $splitDefault -Type DWord
    Write-Host "change: service split threshold $splitNow KB -> $splitDefault KB (the Windows default)"
    $changes++; $reboot = $true
}

# ---- the session key must not reach a disk in the clear (exception X23) ------------
# An operator session keeps the decrypted age key in WSL's memory. This disk
# is not encrypted, so the three ways memory reaches it are closed: WSL's own
# swap file, the Windows page file (encrypted with a key that lives for one
# boot), and the hibernation file.
$fsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
if ((Get-ItemProperty -Path $fsKey -Name NtfsEncryptPagingFile -ErrorAction SilentlyContinue).NtfsEncryptPagingFile -ne 1) {
    & fsutil.exe behavior set EncryptPagingFile 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fsutil could not switch page file encryption on' }
    Write-Host 'change: page file encryption on'
    $changes++; $reboot = $true
}
$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
if ((Get-ItemProperty -Path $powerKey -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled -ne 0) {
    & powercfg.exe /hibernate off
    if ($LASTEXITCODE -ne 0) { throw 'powercfg could not switch hibernation off' }
    Write-Host 'change: hibernation off (and with it fast startup)'
    $changes++
}
# .wslconfig is read and written as UTF-8 without a byte-order mark, like
# pbs-vm.ps1 does for the memory line.
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $cfg) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $bytes = [IO.File]::ReadAllBytes($cfg)
    $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $skip = 3 }
    $text = $utf8.GetString($bytes, $skip, $bytes.Length - $skip)
    if ($text -match '(?m)^[ \t]*swap[ \t]*=') {
        $new = [regex]::Replace($text, '(?m)^[ \t]*swap[ \t]*=.*?(\r?)$', 'swap=0$1')
    }
    elseif ($text -match '(?m)^[ \t]*\[wsl2\][ \t]*\r?$') {
        $new = [regex]::Replace($text, '(?m)^([ \t]*\[wsl2\][ \t]*)(\r?)$', '$1$2' + "`n" + 'swap=0$2')
    }
    else { $new = $text; Write-Host 'note:   .wslconfig has no [wsl2] section; WSL swap not set' }
    if ($new -ne $text -or $skip -ne 0) {
        [IO.File]::WriteAllText($cfg, $new, $utf8)
        Write-Host "change: .wslconfig swap=0 (takes effect after 'wsl --shutdown')"
        $changes++
    }
}
else { Write-Host 'note:   .wslconfig absent; WSL swap not set (docs/runbooks/restore-workstation.md creates the file)' }

if ($changes -eq 0) { Write-Host 'Workstation matches the policy. Nothing was changed.' }
else { Write-Host "$changes change(s)." }
if ($reboot) { Write-Host 'RESTART WINDOWS for the service split and the page file encryption to take effect. Close the operator session first (just session-end).' }
