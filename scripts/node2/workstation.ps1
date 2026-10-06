# Workstation (Node 2) policy. Idempotent; prints only what it changed.
# Run in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\workstation.ps1
#
# The dock port and the Wi-Fi adapter hold two different reserved addresses
# (decision reversed 2026-10-06: one shared address deadlocked Windows, which
# refused the dock's lease while Wi-Fi held the address and would only drop
# Wi-Fi once the dock had connectivity). Both links may be up at once, so no
# connection-manager policy is set; one set earlier is removed here.

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
$p2p = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object InterfaceDescription -match 'USB 2.5GbE|UE302' | Select-Object -First 1
if ($p2p) {
    $pm = Get-NetAdapterPowerManagement -Name $p2p.Name
    if ($pm.AllowComputerToTurnOffDevice -ne 'Disabled' -or $pm.SelectiveSuspend -ne 'Disabled' -or $pm.DeviceSleepOnDisconnect -ne 'Disabled') {
        Disable-NetAdapterPowerManagement -Name $p2p.Name -NoRestart
        Set-NetAdapterPowerManagement -Name $p2p.Name -SelectiveSuspend Disabled -DeviceSleepOnDisconnect Disabled -ErrorAction SilentlyContinue
        Write-Host "change: power management off on '$($p2p.Name)' (direct link adapter)"
        $changes++
    }
}
else { Write-Host 'note:   2.5 GbE adapter not present; its power settings are applied on a run with it plugged in' }

if ($changes -eq 0) { Write-Host 'Workstation matches the policy. Nothing was changed.' }
else { Write-Host "$changes change(s). The connection policy applies to the next link change; no reboot needed." }
