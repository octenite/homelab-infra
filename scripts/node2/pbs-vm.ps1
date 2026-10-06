# Backup server VM on the workstation (Node 2), Hyper-V. Idempotent: every run
# converges the switches, NAT, VM, disks, port ACLs, firewall, port forward
# and the WSL memory cap, and prints only what it changed.
#
# Run in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1                 converge
#   ... -Iso F:\homelab\iso\pbs1-auto.iso                                             attach the install media, boot from it once
#   ... -Eject                                                                        detach the media after the install
#   ... -Recreate                                                                     remove the VM (disks are kept) and build it again
#
# Design: docs/ARCHITECTURE.md sections 4 and 6; component docs/components/pbs.md.
# The direct 2.5 GbE link (switch "p2p") is configured only while the USB
# adapter is present; the NAT path (switch "pbs-nat") always exists and the
# port forward on 8007 is the fallback path (E14).
#
# Generation 1 (BIOS), not 2: the Proxmox installer's early environment has
# no synthetic Hyper-V keyboard or storage driver, so on a Generation 2 VM it
# finds neither its DVD nor the console keyboard (seen 2026-10-06). The
# emulated IDE and PS/2 devices of a Generation 1 VM work; the installed
# system uses the synthetic drivers. Secure Boot is therefore unavailable
# (exception X7).

#   ... -WipeDatastore                                                                delete the datastore disk file (VM off); it is created again empty
#   ... -WipeSystem                                                                   delete the system disk file (VM off); it is created again empty
#
# The datastore disk is detached while the install medium is attached and
# attached again afterwards: with two disks present the installer's disk
# names are not stable (seen 2026-10-06: it installed onto the datastore
# disk), with one disk there is nothing to confuse.

[CmdletBinding()]
param(
    [string]$Iso,
    [switch]$Eject,
    [switch]$Recreate,
    [switch]$WipeDatastore,
    [switch]$WipeSystem
)

$ErrorActionPreference = 'Stop'

# ---- settings -------------------------------------------------------------
$VmName = 'pbs1'
$Root = 'F:\homelab\pbs1'
$MemoryGB = 4          # fixed; owner decision 2026-10-06
$Cpu = 2
$SystemGB = 32
$DatastoreGB = 128     # fixed VHDX
$NatSwitch = 'pbs-nat'
$NatPrefix = '10.0.98.0/29'
$NatHost = '10.0.98.1'
$NatPbs = '10.0.98.3'
$P2pSwitch = 'p2p'
$P2pAdapterPattern = 'USB 2.5GbE|UE302'
$P2pHost = '10.0.99.2'
$MacNat = '00155D980003'
$MacP2p = '00155D990003'
$PveAddress = '10.0.10.10'
$WslMemory = '5GB'
# ---------------------------------------------------------------------------

$changes = New-Object System.Collections.ArrayList
function Step($msg) { [void]$changes.Add($msg); Write-Host "change: $msg" }
function Note($msg) { Write-Host "note:   $msg" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated PowerShell.' }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell module not available.' }

# ---- NAT switch: always present; PBS egress and the fallback path ----------
if (-not (Get-VMSwitch -Name $NatSwitch -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $NatSwitch -SwitchType Internal | Out-Null
    Step "switch $NatSwitch (internal)"
}
$natIf = Get-NetAdapter -Name "vEthernet ($NatSwitch)"
if (-not (Get-NetIPAddress -InterfaceIndex $natIf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $NatHost)) {
    New-NetIPAddress -InterfaceIndex $natIf.ifIndex -IPAddress $NatHost -PrefixLength 29 | Out-Null
    Step "host address $NatHost/29 on $NatSwitch"
}
if (-not (Get-NetNat -Name $NatSwitch -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $NatSwitch -InternalIPInterfaceAddressPrefix $NatPrefix | Out-Null
    Step "nat $NatPrefix"
}

# ---- direct link: only while the 2.5 GbE adapter is plugged in -------------
$p2pAdapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object InterfaceDescription -match $P2pAdapterPattern | Select-Object -First 1
if ($p2pAdapter) {
    if (-not (Get-VMSwitch -Name $P2pSwitch -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $P2pSwitch -NetAdapterName $p2pAdapter.Name -AllowManagementOS $true | Out-Null
        Step "switch $P2pSwitch on '$($p2pAdapter.Name)'"
    }
    $p2pIf = Get-NetAdapter -Name "vEthernet ($P2pSwitch)"
    if (-not (Get-NetIPAddress -InterfaceIndex $p2pIf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $P2pHost)) {
        Set-NetIPInterface -InterfaceIndex $p2pIf.ifIndex -AddressFamily IPv4 -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $p2pIf.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
        New-NetIPAddress -InterfaceIndex $p2pIf.ifIndex -IPAddress $P2pHost -PrefixLength 29 | Out-Null
        Step "host address $P2pHost/29 on $P2pSwitch (no gateway)"
    }
    $prof = Get-NetConnectionProfile -InterfaceIndex $p2pIf.ifIndex -ErrorAction SilentlyContinue
    if ($prof -and $prof.NetworkCategory -ne 'Public') {
        Set-NetConnectionProfile -InterfaceIndex $p2pIf.ifIndex -NetworkCategory Public
        Step "$P2pSwitch profile pinned to Public"
    }
}
else {
    Note '2.5 GbE adapter not present: the direct link is configured on a run with it plugged in'
}

# ---- VM ---------------------------------------------------------------------
$sysVhd = "$Root\disks\system.vhdx"
$dataVhd = "$Root\disks\datastore.vhdx"
$existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existing -and $Recreate) {
    if ($existing.State -ne 'Off') { Stop-VM -Name $VmName -TurnOff -Force; Step 'vm turned off for recreation' }
    Remove-VM -Name $VmName -Force
    Step 'vm removed (disk files kept)'
    $existing = $null
}
if ($existing -and $existing.Generation -ne 1) {
    throw "$VmName exists as generation $($existing.Generation); run again with -Recreate (disks are kept)."
}
if (-not $existing) {
    New-Item -ItemType Directory -Force "$Root\disks" | Out-Null
    if (Test-Path $sysVhd) {
        New-VM -Name $VmName -Generation 1 -MemoryStartupBytes ($MemoryGB * 1GB) -Path $Root -VHDPath $sysVhd -SwitchName $NatSwitch | Out-Null
        Step "vm $VmName (generation 1, existing system disk)"
    }
    else {
        New-VM -Name $VmName -Generation 1 -MemoryStartupBytes ($MemoryGB * 1GB) -Path $Root `
            -NewVHDPath $sysVhd -NewVHDSizeBytes ($SystemGB * 1GB) -SwitchName $NatSwitch | Out-Null
        Step "vm $VmName (generation 1, $SystemGB GiB system disk)"
    }
}
$vm = Get-VM -Name $VmName
$off = $vm.State -eq 'Off'

if ($vm.DynamicMemoryEnabled -or $vm.MemoryStartup -ne ($MemoryGB * 1GB)) {
    if ($off) { Set-VM -Name $VmName -StaticMemory -MemoryStartupBytes ($MemoryGB * 1GB); Step "memory fixed at $MemoryGB GiB" }
    else { Note 'memory differs; needs the VM off' }
}
if ($vm.ProcessorCount -ne $Cpu) {
    if ($off) { Set-VM -Name $VmName -ProcessorCount $Cpu; Step "$Cpu vCPU" } else { Note 'vCPU count differs; needs the VM off' }
}
if ($vm.AutomaticStartAction -ne 'Nothing') { Set-VM -Name $VmName -AutomaticStartAction Nothing; Step 'started by hand (owner decision)' }
if ($vm.AutomaticStopAction -ne 'ShutDown') { Set-VM -Name $VmName -AutomaticStopAction ShutDown; Step 'clean shutdown with the host' }
if ($vm.CheckpointType -ne 'Disabled' -or $vm.AutomaticCheckpointsEnabled) {
    Set-VM -Name $VmName -CheckpointType Disabled -AutomaticCheckpointsEnabled $false; Step 'checkpoints disabled'
}

if ($WipeSystem) {
    if (-not $off) { throw 'WipeSystem needs the VM off.' }
    $sysDrive = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $sysVhd
    if ($sysDrive) { $sysDrive | Remove-VMHardDiskDrive; Step 'system disk detached' }
    if (Test-Path $sysVhd) { Remove-Item $sysVhd -Force; Step 'system disk file deleted' }
    New-VHD -Path $sysVhd -SizeBytes ($SystemGB * 1GB) -Dynamic | Out-Null
    Add-VMHardDiskDrive -VMName $VmName -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $sysVhd
    Step "system disk $SystemGB GiB created empty and attached (IDE 0:0)"
}

$dataDrive = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $dataVhd
if ($WipeDatastore) {
    if (-not $off) { throw 'WipeDatastore needs the VM off.' }
    if ($dataDrive) { $dataDrive | Remove-VMHardDiskDrive; $dataDrive = $null; Step 'datastore disk detached' }
    if (Test-Path $dataVhd) { Remove-Item $dataVhd -Force; Step 'datastore disk file deleted' }
}
if (-not (Test-Path $dataVhd)) {
    New-VHD -Path $dataVhd -SizeBytes ($DatastoreGB * 1GB) -Fixed | Out-Null
    Step "datastore disk $DatastoreGB GiB, fixed"
}
if ($Iso) {
    if ($dataDrive) {
        if (-not $off) { throw 'Attaching the install medium needs the VM off.' }
        $dataDrive | Remove-VMHardDiskDrive; Step 'datastore disk detached for the install'
    }
}
elseif (-not $dataDrive) {
    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $dataVhd
    Step 'datastore disk attached (SCSI)'
}

# ---- VM network adapters: static MACs so the installer can pick the NIC ----
$nat = Get-VMNetworkAdapter -VMName $VmName | Where-Object SwitchName -eq $NatSwitch | Select-Object -First 1
if (-not $nat) { throw "no adapter on $NatSwitch" }
if ($nat.Name -ne 'nat') { Rename-VMNetworkAdapter -VMNetworkAdapter $nat -NewName 'nat'; Step "adapter named 'nat'"; $nat = Get-VMNetworkAdapter -VMName $VmName -Name nat }
if ($nat.MacAddress -ne $MacNat) {
    if ($off) { Set-VMNetworkAdapter -VMNetworkAdapter $nat -StaticMacAddress $MacNat; Step "nat adapter MAC $MacNat" } else { Note 'nat MAC differs; needs the VM off' }
}
if (Get-VMSwitch -Name $P2pSwitch -ErrorAction SilentlyContinue) {
    if (-not (Get-VMNetworkAdapter -VMName $VmName -Name p2p -ErrorAction SilentlyContinue)) {
        Add-VMNetworkAdapter -VMName $VmName -Name p2p -SwitchName $P2pSwitch -StaticMacAddress $MacP2p
        Step "adapter 'p2p' on $P2pSwitch, MAC $MacP2p"
    }
}

# ---- port ACLs: the NAT leg reaches the host and the internet, never the lab
function Normalize-Net($s) { ($s -replace '/32$', '').ToLower() }
function Ensure-Acl($adapter, $remote, $action) {
    # Hyper-V stores entries in its own spelling (for example without "/32"),
    # so compare normalised, and treat "already exists" as present.
    $have = Get-VMNetworkAdapterAcl -VMName $VmName -VMNetworkAdapterName $adapter |
    Where-Object { (Normalize-Net $_.RemoteIPAddress) -eq (Normalize-Net $remote) -and $_.Direction -eq 'Both' -and $_.Action -eq $action }
    if (-not $have) {
        try {
            Add-VMNetworkAdapterAcl -VMName $VmName -VMNetworkAdapterName $adapter -RemoteIPAddress $remote -Direction Both -Action $action
            Step "acl $adapter $action $remote"
        }
        catch {
            if ($_.Exception.Message -match '0x800700B7|already exists') { Note "acl $adapter $action $remote already present" }
            else { throw }
        }
    }
}
foreach ($net in '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16') { Ensure-Acl 'nat' $net 'Deny' }
Ensure-Acl 'nat' "$NatHost/32" 'Allow'
if (Get-VMNetworkAdapter -VMName $VmName -Name p2p -ErrorAction SilentlyContinue) {
    Ensure-Acl 'p2p' '0.0.0.0/0' 'Deny'
    Ensure-Acl 'p2p' '10.0.99.1/32' 'Allow'
}

# ---- host firewall and the fallback port forward (E14) ---------------------
if (-not (Get-NetFirewallRule -Name 'homelab-pbs1-8007' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'homelab-pbs1-8007' -DisplayName 'homelab: backup server 8007 from the hypervisor' `
        -Direction Inbound -Protocol TCP -LocalPort 8007 -RemoteAddress $PveAddress -Action Allow -Profile Any | Out-Null
    Step "firewall: inbound 8007 from $PveAddress only"
}
if ((Get-VMSwitch -Name $P2pSwitch -ErrorAction SilentlyContinue) -and -not (Get-NetFirewallRule -Name 'homelab-p2p-inbound-block' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'homelab-p2p-inbound-block' -DisplayName 'homelab: nothing inbound on the direct link' `
        -Direction Inbound -InterfaceAlias "vEthernet ($P2pSwitch)" -Action Block -Profile Any | Out-Null
    Step 'firewall: all inbound blocked on the direct link'
}
$svc = Get-Service iphlpsvc
if ($svc.StartType -ne 'Automatic') { Set-Service iphlpsvc -StartupType Automatic; Step 'IP Helper service automatic (port forward)' }
if ($svc.Status -ne 'Running') { Start-Service iphlpsvc; Step 'IP Helper service started' }
$proxy = netsh interface portproxy show v4tov4 | Select-String -Pattern "^\s*0\.0\.0\.0\s+8007\s+$([regex]::Escape($NatPbs))\s+8007"
if (-not $proxy) {
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=8007 connectaddress=$NatPbs connectport=8007 | Out-Null
    Step "port forward 8007 -> $NatPbs"
}
# Ansible runs in WSL, whose NAT network Windows does not route to the VM's
# switch: SSH reaches the VM through a second forward, open to WSL only.
if (-not (Get-NetFirewallRule -Name 'homelab-pbs1-ssh-wsl' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'homelab-pbs1-ssh-wsl' -DisplayName 'homelab: backup server SSH from WSL' `
        -Direction Inbound -Protocol TCP -LocalPort 2222 -RemoteAddress 172.16.0.0/12 -Action Allow -Profile Any | Out-Null
    Step 'firewall: inbound 2222 from the WSL range only'
}
$proxy = netsh interface portproxy show v4tov4 | Select-String -Pattern "^\s*0\.0\.0\.0\s+2222\s+$([regex]::Escape($NatPbs))\s+22"
if (-not $proxy) {
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=2222 connectaddress=$NatPbs connectport=22 | Out-Null
    Step "port forward 2222 -> $NatPbs:22 (Ansible from WSL)"
}

# ---- WSL memory cap (owner decision 2026-10-06) -----------------------------
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $cfg) {
    $lines = Get-Content $cfg
    $new = $lines | ForEach-Object { if ($_ -match '^\s*memory\s*=') { "memory=$WslMemory" } else { $_ } }
    if (($new -join "`n") -ne ($lines -join "`n")) {
        Set-Content -Path $cfg -Value $new -Encoding UTF8
        Step ".wslconfig memory=$WslMemory (takes effect after 'wsl --shutdown')"
    }
}
else { Note '.wslconfig absent; WSL cap not set' }

# ---- install media (IDE DVD; BIOS boot order) -------------------------------
if ($Iso) {
    if (-not (Test-Path $Iso)) { throw "ISO not found: $Iso" }
    $dvd = Get-VMDvdDrive -VMName $VmName | Select-Object -First 1
    if (-not $dvd) { Add-VMDvdDrive -VMName $VmName -Path $Iso; Step 'dvd drive added' }
    elseif ($dvd.Path -ne $Iso) { Set-VMDvdDrive -VMName $VmName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $Iso; Step "dvd: $Iso" }
    if ((Get-VM -Name $VmName).State -eq 'Off') { Start-VM -Name $VmName; Step 'vm started; an empty system disk falls through to the install media' }
}
if ($Eject) {
    $dvd = Get-VMDvdDrive -VMName $VmName | Select-Object -First 1
    if ($dvd -and $dvd.Path) { Set-VMDvdDrive -VMName $VmName -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $null; Step 'install media detached' }
}
# The system disk always boots first: an empty disk falls through to the
# DVD, an installed one never re-enters the installer (which would wipe it).
if ((Get-VMBios -VMName $VmName).StartupOrder[0] -ne 'IDE') {
    Set-VMBios -VMName $VmName -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy'); Step 'boot order: system disk first, then dvd'
}

# ---- summary ----------------------------------------------------------------
if ($changes.Count -eq 0) { Write-Host "$VmName matches the script. Nothing was changed." }
else { Write-Host "$($changes.Count) change(s)." }
Get-VM -Name $VmName | Select-Object Name, State, @{n = 'MemoryGB'; e = { $_.MemoryStartup / 1GB } }, ProcessorCount, AutomaticStartAction | Format-Table -AutoSize
Get-VMNetworkAdapter -VMName $VmName | Select-Object Name, SwitchName, MacAddress, IPAddresses | Format-Table -AutoSize
