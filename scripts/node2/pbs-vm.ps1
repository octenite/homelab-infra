# Backup server VM on the workstation (Node 2), Hyper-V. Idempotent: every run
# converges the switches, NAT, VM, disks, port ACLs, firewall rules, port
# forwards and the WSL memory cap by comparing content, and prints only what
# it changed.
#
# Run in an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1            converge; the management window is closed
#   ... -Manage                                                                  converge and open the management window (SSH from WSL)
#   ... -Iso F:\homelab\iso\pbs1-auto.iso                                        attach the install medium (VM off) and start the VM
#   ... -Eject                                                                   detach the medium after the install and delete the image
#   ... -Recreate      -Yes 'recreate pbs1'                                      remove the VM definition (disk files are kept), build it again
#   ... -WipeSystem    -Yes 'delete pbs1 system'                                 replace the system disk with an empty one (VM off)
#   ... -WipeDatastore -Yes 'delete pbs1 datastore'                              replace the datastore disk with an empty one (VM off): every backup is gone
#
# Design: docs/ARCHITECTURE.md sections 4 and 6; component docs/components/pbs.md.
#
# Network legs of the VM
#   nat  switch "pbs-nat" (internal, NetNat): internet egress; the Windows
#        host forwards the backup port to it. Always present.
#   p2p  switch "p2p" (external, on the direct-link adapter): the primary
#        path from the hypervisor. Configured while an adapter is present.
#
# What the Windows host admits (docs/components/pbs.md, "Fences")
#   tcp 8007 from the hypervisor's management address only (E14), forwarded
#     to the VM.
#   tcp 2222 from WSL only, forwarded to the VM's SSH port, and only while
#     the management window is open (-Manage). A plain run closes it.
#   nothing from the direct link and nothing from the VM.
# The allow rules alone do not enforce that: on this machine Windows services
# share one process (SvcHostSplitThresholdInKB), and a built-in rule that
# admits any port of one service in that process (Hyper-V's WMI rule) then
# admits the forwarded ports from every source on every network (found by
# the deny test of 2026-10-06). Block rules win over allow rules, so every
# port forward gets a block rule for all other sources, and the two lab
# segments get block rules by address. Rules name addresses, never
# interfaces: a rule bound to an interface is bound to its GUID and silently
# stops matching when the virtual adapter is created again.
#
# Generation 1 (BIOS), not 2: the Proxmox installer's early environment has
# no synthetic Hyper-V keyboard or storage driver, so on a Generation 2 VM it
# finds neither its DVD nor the console keyboard (seen 2026-10-06). The
# emulated IDE and PS/2 devices of a Generation 1 VM work; the installed
# system uses the synthetic drivers. Secure Boot is therefore unavailable
# (exception X7).
#
# Disks: the datastore disk is attached exactly when no install medium is in
# the drive. With two disks present the installer's disk names are not
# stable (seen 2026-10-06: it installed onto the datastore disk); with one
# disk there is nothing to confuse.

[CmdletBinding()]
param(
    [string]$Iso,
    [switch]$Eject,
    [switch]$Manage,
    [switch]$Recreate,
    [switch]$WipeDatastore,
    [switch]$WipeSystem,
    [string]$Yes
)

$ErrorActionPreference = 'Stop'
# The networking cmdlets (firewall, addresses, NAT, adapters) are script
# modules that keep their own error preference: started as `.\pbs-vm.ps1`
# instead of `powershell -File`, their failures would not stop this script
# and a rule that was never created would be reported as done. A table in
# this script's scope makes every cmdlet stop on error, however the script is
# started, and leaves the calling session alone.
$PSDefaultParameterValues = @{ '*:ErrorAction' = 'Stop' }

# ---- settings -------------------------------------------------------------
$VmName = 'pbs1'
$Root = 'F:\homelab\pbs1'
$IsoDir = 'F:\homelab\iso'
$MemoryGB = 4          # fixed; owner decision 2026-10-06
$Cpu = 2
$SystemGB = 32
$DatastoreGB = 128     # fixed VHDX
$NatSwitch = 'pbs-nat'
$NatPrefix = '10.0.98.0/29'
$NatHost = '10.0.98.1'
$NatPbs = '10.0.98.3'
$NatGuests = '10.0.98.2-10.0.98.6'
$P2pSwitch = 'p2p'
# Direct-link adapters in order of preference: the USB 2.5 GbE adapter, else
# the laptop's own gigabit port (fallback F1). The one with link wins.
$P2pAdapterPatterns = @('USB 2.5GbE|UE302', 'Realtek PCIe GbE')
$P2pHost = '10.0.99.2'
$P2pNet = '10.0.99.0-10.0.99.7'
$P2pPve = '10.0.99.1'
$MacNat = '00155D980003'
$MacP2p = '00155D990003'
$PveAddress = '10.0.10.10'
$WslRange = '172.16.0.0-172.31.255.255'   # WSL's NAT network is somewhere in 172.16.0.0/12 after every start
$BackupPort = 8007
$SshForwardPort = 2222
$WslMemory = '5GB'
# ---------------------------------------------------------------------------

$changes = New-Object System.Collections.ArrayList
function Step($msg) { [void]$changes.Add($msg); Write-Host "change: $msg" }
function Note($msg) { Write-Host "note:   $msg" }
function Invoke-Netsh {
    # netsh is a native command: its failure does not stop the script by
    # itself, so the exit code is checked. (No stderr redirection: under
    # ErrorActionPreference Stop that turns any stderr line into a throw.)
    $out = & netsh @args
    if ($LASTEXITCODE -ne 0) { throw "netsh $($args -join ' ') failed: $($out -join ' ')" }
    return $out
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this in an elevated PowerShell.' }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Hyper-V PowerShell module not available.' }

# ---- checks before anything changes -----------------------------------------
if ($Iso -and $Eject) { throw '-Iso and -Eject cannot be combined: attach, let the installer finish, then eject.' }
if ($Iso -and -not (Test-Path -LiteralPath $Iso)) { throw "ISO not found: $Iso" }
if ($WipeDatastore -and $WipeSystem) { throw 'One wipe at a time: run -WipeSystem and -WipeDatastore separately.' }
$destructive = @()
if ($Recreate) { $destructive += @{ Switch = '-Recreate'; Phrase = "recreate $VmName"; What = 'turns the VM off and removes its definition (the disk files are kept)' } }
if ($WipeSystem) { $destructive += @{ Switch = '-WipeSystem'; Phrase = "delete $VmName system"; What = 'deletes the system disk of the VM' } }
if ($WipeDatastore) { $destructive += @{ Switch = '-WipeDatastore'; Phrase = "delete $VmName datastore"; What = 'deletes the datastore disk and every backup on it; it is never part of a system rebuild' } }
if ($destructive.Count -gt 1) { throw 'One destructive switch at a time.' }
if ($destructive.Count -eq 1 -and $Yes -ne $destructive[0].Phrase) {
    throw "$($destructive[0].Switch) $($destructive[0].What). Nothing was changed. To go ahead, repeat the command with:  -Yes '$($destructive[0].Phrase)'"
}
$vmBefore = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (($Iso -or $WipeSystem -or $WipeDatastore) -and $vmBefore -and $vmBefore.State -ne 'Off' -and -not $Recreate) {
    throw "This needs the VM off: Stop-VM $VmName, then run again."
}

# ---- NAT switch: always present; VM egress and the forwarded paths ----------
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

# ---- direct link: only while an adapter for it is present -------------------
$p2pCandidates = foreach ($pat in $P2pAdapterPatterns) { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object InterfaceDescription -match $pat }
$p2pAdapter = ($p2pCandidates | Where-Object Status -eq 'Up' | Select-Object -First 1)
if (-not $p2pAdapter) { $p2pAdapter = $p2pCandidates | Select-Object -First 1 }
if ($p2pAdapter) {
    $sw = Get-VMSwitch -Name $P2pSwitch -ErrorAction SilentlyContinue
    if (-not $sw) {
        New-VMSwitch -Name $P2pSwitch -NetAdapterName $p2pAdapter.Name -AllowManagementOS $true | Out-Null
        Step "switch $P2pSwitch on '$($p2pAdapter.Name)'"
    }
    elseif ($sw.NetAdapterInterfaceDescription -ne $p2pAdapter.InterfaceDescription -and $p2pAdapter.Status -eq 'Up') {
        Set-VMSwitch -Name $P2pSwitch -NetAdapterName $p2pAdapter.Name
        Step "switch $P2pSwitch moved to '$($p2pAdapter.Name)' (the adapter with link)"
    }
    $p2pIf = Get-NetAdapter -Name "vEthernet ($P2pSwitch)"
    $p2pPersistent = Get-NetIPAddress -InterfaceIndex $p2pIf.ifIndex -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $P2pHost
    if (-not $p2pPersistent) {
        # netsh sets the static address and turns DHCP off in both stores in
        # one step; the PowerShell pair refuses with "inconsistent parameters".
        Invoke-Netsh interface ipv4 set address "name=$($p2pIf.Name)" source=static "address=$P2pHost" mask=255.255.255.248 | Out-Null
        Step "host address $P2pHost/29 on $P2pSwitch (no gateway)"
    }
    $prof = Get-NetConnectionProfile -InterfaceIndex $p2pIf.ifIndex -ErrorAction SilentlyContinue
    if ($prof -and $prof.NetworkCategory -ne 'Public') {
        Set-NetConnectionProfile -InterfaceIndex $p2pIf.ifIndex -NetworkCategory Public
        Step "$P2pSwitch profile pinned to Public"
    }
}
else {
    Note 'no direct-link adapter present: the direct link is configured on a run with it plugged in'
}

# The two lab segments carry IPv4 only. Without IPv6 on the host side, the
# VM and the hypervisor cannot reach the host over link-local addresses,
# which the address-based block rules below would not cover.
foreach ($n in "vEthernet ($NatSwitch)", "vEthernet ($P2pSwitch)") {
    $b = Get-NetAdapterBinding -Name $n -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    if ($b -and $b.Enabled) {
        Disable-NetAdapterBinding -Name $n -ComponentID ms_tcpip6
        Step "IPv6 unbound from '$n'"
    }
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
    throw "$VmName exists as generation $($existing.Generation); run again with -Recreate -Yes 'recreate $VmName' (disks are kept)."
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

# The system disk always boots first: an empty disk falls through to the
# DVD, an installed one never re-enters the installer (which would wipe it).
# Set before the VM can be started by this run.
if ((Get-VMBios -VMName $VmName).StartupOrder[0] -ne 'IDE') {
    if ($off) { Set-VMBios -VMName $VmName -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy'); Step 'boot order: system disk first, then dvd' }
    else { Note 'boot order differs; needs the VM off' }
}

# ---- disks and install medium -------------------------------------------------
if ($WipeSystem) {
    $sysDrive = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $sysVhd
    if ($sysDrive) { $sysDrive | Remove-VMHardDiskDrive; Step 'system disk detached' }
    if (Test-Path $sysVhd) { Remove-Item $sysVhd -Force; Step 'system disk file deleted' }
    New-VHD -Path $sysVhd -SizeBytes ($SystemGB * 1GB) -Dynamic | Out-Null
    Add-VMHardDiskDrive -VMName $VmName -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $sysVhd
    Step "system disk $SystemGB GiB created empty and attached (IDE 0:0)"
    if (-not $Iso) { Note "the system disk is empty: install with -Iso <image>" }
}

$dataDrive = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $dataVhd
if ($WipeDatastore) {
    if ($dataDrive) { $dataDrive | Remove-VMHardDiskDrive; $dataDrive = $null; Step 'datastore disk detached' }
    if (Test-Path $dataVhd) { Remove-Item $dataVhd -Force; Step 'datastore disk file deleted' }
}
if (-not (Test-Path $dataVhd)) {
    New-VHD -Path $dataVhd -SizeBytes ($DatastoreGB * 1GB) -Fixed | Out-Null
    Step "datastore disk $DatastoreGB GiB, fixed"
}

$dvd = Get-VMDvdDrive -VMName $VmName | Select-Object -First 1
$mediaNow = if ($dvd) { $dvd.Path } else { $null }
function Set-Media($path) {
    $d = Get-VMDvdDrive -VMName $VmName | Select-Object -First 1
    if (-not $d) { Add-VMDvdDrive -VMName $VmName -Path $path; return }
    Set-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $path
}
function Remove-InstallImage($path) {
    # The prepared image embeds the answer file with the root password hash;
    # it is rebuilt on demand and never kept (X2, X23).
    foreach ($p in @($path, "$IsoDir\$VmName-auto.iso") | Where-Object { $_ } | Select-Object -Unique) {
        if ($p -like "$IsoDir\*" -and (Test-Path -LiteralPath $p)) {
            Remove-Item -LiteralPath $p -Force
            Step "install image deleted: $p (it embeds the password hash; scripts/pbs/build-install-iso.sh rebuilds it)"
        }
    }
}
if ($Iso) {
    if ($dataDrive) { $dataDrive | Remove-VMHardDiskDrive; $dataDrive = $null; Step 'datastore disk detached for the install' }
    if ($mediaNow -ne $Iso) { Set-Media $Iso; Step "install medium attached: $Iso" }
}
elseif ($Eject) {
    if ($mediaNow) { Set-Media $null; Step 'install medium detached' }
    Remove-InstallImage $mediaNow
    if (-not $dataDrive) { Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $dataVhd; Step 'datastore disk attached (SCSI)' }
}
elseif ($mediaNow -and $dataDrive) {
    # Both present: an unbootable system disk would fall through to an
    # unattended installer that can see the datastore. The medium goes.
    Set-Media $null
    Step "stale install medium removed from the drive (the datastore disk is attached): $mediaNow"
}
elseif ($mediaNow) {
    Note "install medium is in the drive and the datastore disk stays detached: run -Eject once the installer has finished"
}
elseif (-not $dataDrive) {
    Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $dataVhd
    Step 'datastore disk attached (SCSI)'
}

# ---- VM network adapters: static MACs so the installer can pick the NIC ----
$nat = Get-VMNetworkAdapter -VMName $VmName | Where-Object SwitchName -eq $NatSwitch | Select-Object -First 1
if (-not $nat) {
    $nat = Get-VMNetworkAdapter -VMName $VmName | Where-Object { $_.Name -eq 'nat' -or -not $_.SwitchName } | Select-Object -First 1
    if (-not $nat) { throw "the VM has no adapter for $NatSwitch" }
    Connect-VMNetworkAdapter -VMNetworkAdapter $nat -SwitchName $NatSwitch
    Step "adapter '$($nat.Name)' connected to $NatSwitch"
}
if ($nat.Name -ne 'nat') { Rename-VMNetworkAdapter -VMNetworkAdapter $nat -NewName 'nat'; Step "adapter named 'nat'"; $nat = Get-VMNetworkAdapter -VMName $VmName -Name nat }
if ($nat.MacAddress -ne $MacNat) {
    if ($off) { Set-VMNetworkAdapter -VMNetworkAdapter $nat -StaticMacAddress $MacNat; Step "nat adapter MAC $MacNat" } else { Note 'nat MAC differs; needs the VM off' }
}
if (Get-VMSwitch -Name $P2pSwitch -ErrorAction SilentlyContinue) {
    $p2pVm = Get-VMNetworkAdapter -VMName $VmName -Name p2p -ErrorAction SilentlyContinue
    if (-not $p2pVm) {
        if ($off) {
            Add-VMNetworkAdapter -VMName $VmName -Name p2p -SwitchName $P2pSwitch -StaticMacAddress $MacP2p
            Step "adapter 'p2p' on $P2pSwitch, MAC $MacP2p"
        }
        else { Note "adapter 'p2p' is added when the VM is off (Stop-VM $VmName, run again, Start-VM $VmName)" }
    }
    else {
        if ($p2pVm.SwitchName -ne $P2pSwitch) {
            Connect-VMNetworkAdapter -VMNetworkAdapter $p2pVm -SwitchName $P2pSwitch
            Step "adapter 'p2p' connected to $P2pSwitch again"
        }
        if ($p2pVm.MacAddress -ne $MacP2p) {
            if ($off) { Set-VMNetworkAdapter -VMNetworkAdapter $p2pVm -StaticMacAddress $MacP2p; Step "p2p adapter MAC $MacP2p" } else { Note 'p2p MAC differs; needs the VM off' }
        }
    }
}

# ---- port ACLs: exactly the wanted entries on each adapter --------------------
# The NAT leg reaches the Windows host (its gateway) and the internet, never
# a private range; the direct-link leg reaches the hypervisor and nothing
# else. Entries belong to an adapter and vanish with it, so they are asserted
# on every run; anything else found there is removed.
function Format-Net($s) {
    # Hyper-V spells stored entries its own way: a host without "/32", and
    # possibly "ANY" for everything.
    $t = ("$s" -replace '/32$', '').ToLower()
    if ($t -in 'any', '*') { return '0.0.0.0/0' }
    return $t
}
function Sync-Acl($adapter, $wanted) {
    $have = @(Get-VMNetworkAdapterAcl -VMName $VmName -VMNetworkAdapterName $adapter | Where-Object RemoteIPAddress)
    $wantKeys = foreach ($w in $wanted) { foreach ($d in 'Inbound', 'Outbound') { "$($w.Action)|$(Format-Net $w.Remote)|$d" } }
    $haveKeys = New-Object System.Collections.ArrayList
    foreach ($h in $have) {
        $dirs = if ("$($h.Direction)" -eq 'Both') { 'Inbound', 'Outbound' } else { , "$($h.Direction)" }
        $keys = foreach ($d in $dirs) { "$($h.Action)|$(Format-Net $h.RemoteIPAddress)|$d" }
        if (@($keys | Where-Object { $wantKeys -notcontains $_ }).Count -gt 0) {
            Remove-VMNetworkAdapterAcl -VMName $VmName -VMNetworkAdapterName $adapter -RemoteIPAddress $h.RemoteIPAddress -Direction $h.Direction -Action $h.Action
            Step "acl $adapter removed: $($h.Action) $($h.RemoteIPAddress) $($h.Direction)"
        }
        else { foreach ($k in $keys) { [void]$haveKeys.Add($k) } }
    }
    foreach ($w in $wanted) {
        foreach ($d in 'Inbound', 'Outbound') {
            if ($haveKeys -contains "$($w.Action)|$(Format-Net $w.Remote)|$d") { continue }
            try {
                Add-VMNetworkAdapterAcl -VMName $VmName -VMNetworkAdapterName $adapter -RemoteIPAddress $w.Remote -Direction $d -Action $w.Action
                Step "acl $adapter $($w.Action) $($w.Remote) $d"
            }
            catch {
                # Hyper-V spells stored entries its own way; an entry that it
                # reports as existing is present.
                if ($_.Exception.Message -notmatch '0x800700B7|already exists') { throw }
            }
        }
    }
}
Sync-Acl 'nat' @(
    @{ Action = 'Deny'; Remote = '10.0.0.0/8' },
    @{ Action = 'Deny'; Remote = '172.16.0.0/12' },
    @{ Action = 'Deny'; Remote = '192.168.0.0/16' },
    @{ Action = 'Allow'; Remote = "$NatHost/32" }
)
if (Get-VMNetworkAdapter -VMName $VmName -Name p2p -ErrorAction SilentlyContinue) {
    Sync-Acl 'p2p' @(
        @{ Action = 'Deny'; Remote = '0.0.0.0/0' },
        @{ Action = 'Allow'; Remote = "$P2pPve/32" }
    )
}

# ---- host firewall: allow rules, and block rules that hold whatever else is configured
function ConvertTo-Number([string]$ip) {
    $b = [System.Net.IPAddress]::Parse($ip.Trim()).GetAddressBytes()
    return ([long]$b[0] * 16777216) + ([long]$b[1] * 65536) + ([long]$b[2] * 256) + [long]$b[3]
}
function ConvertFrom-Number([long]$n) {
    return "{0}.{1}.{2}.{3}" -f [math]::Floor($n / 16777216), ([math]::Floor($n / 65536) % 256), ([math]::Floor($n / 256) % 256), ($n % 256)
}
function ConvertTo-Span([string]$s) {
    # Windows returns addresses in several spellings (single, range, prefix
    # length, dotted mask); all of them become "first-last" as numbers.
    $s = $s.Trim()
    if ($s -eq 'Any') { return 'Any' }
    if ($s -match '^([\d.]+)-([\d.]+)$') { return "$(ConvertTo-Number $Matches[1])-$(ConvertTo-Number $Matches[2])" }
    if ($s -match '^([\d.]+)/(\d+)$') {
        $base = ConvertTo-Number $Matches[1]; $size = [long]1 -shl (32 - [int]$Matches[2])
        $first = $base - ($base % $size); return "$first-$($first + $size - 1)"
    }
    if ($s -match '^([\d.]+)/([\d.]+)$') {
        $base = ConvertTo-Number $Matches[1]; $size = 4294967296 - (ConvertTo-Number $Matches[2])
        $first = $base - ($base % $size); return "$first-$($first + $size - 1)"
    }
    $n = ConvertTo-Number $s; return "$n-$n"
}
function Get-Spans($list) { (@($list) | ForEach-Object { ConvertTo-Span "$_" } | Sort-Object) -join ' ' }
function Get-Others([string]$range) {
    # Everything outside one address or one "first-last" range. Two spellings:
    # Windows versions differ on whether a range may touch 0.0.0.0 and
    # 255.255.255.255.
    $span = ConvertTo-Span $range
    $first, $last = $span -split '-' | ForEach-Object { [long]$_ }
    $wide = @("0.0.0.0-$(ConvertFrom-Number ($first - 1))", "$(ConvertFrom-Number ($last + 1))-255.255.255.255")
    $narrow = @("1.0.0.0-$(ConvertFrom-Number ($first - 1))", "$(ConvertFrom-Number ($last + 1))-255.255.255.254")
    return @{ Wide = $wide; Narrow = $narrow }
}
function Test-Rule($spec) {
    $r = Get-NetFirewallRule -Name $spec.Name -ErrorAction SilentlyContinue
    if (-not $r) { return $false }
    if ("$($r.Enabled)" -ne 'True' -or "$($r.Direction)" -ne 'Inbound' -or "$($r.Action)" -ne $spec.Action -or "$($r.Profile)" -ne 'Any') { return $false }
    $pf = $r | Get-NetFirewallPortFilter
    $wantPort = if ($spec.Port) { "$($spec.Port)" } else { 'Any' }
    if ("$($pf.Protocol)" -ne $spec.Protocol -or (@($pf.LocalPort) -join ',') -ne $wantPort) { return $false }
    $af = $r | Get-NetFirewallAddressFilter
    if ((@($af.LocalAddress) -join ',') -ne 'Any') { return $false }
    $have = Get-Spans $af.RemoteAddress
    if ($have -ne (Get-Spans $spec.Remote) -and -not ($spec.RemoteAlt -and $have -eq (Get-Spans $spec.RemoteAlt))) { return $false }
    if ((@(($r | Get-NetFirewallInterfaceFilter).InterfaceAlias) -join ',') -ne 'Any') { return $false }
    if ("$(($r | Get-NetFirewallApplicationFilter).Program)" -ne 'Any') { return $false }
    return $true
}
function Set-Rule($spec) {
    if (Test-Rule $spec) { return }
    Get-NetFirewallRule -Name $spec.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $p = @{
        Name = $spec.Name; DisplayName = $spec.Display; Description = 'Managed by scripts/node2/pbs-vm.ps1 (homelab-infra)'
        Direction = 'Inbound'; Action = $spec.Action; Profile = 'Any'; RemoteAddress = $spec.Remote
    }
    if ($spec.Protocol -ne 'Any') { $p.Protocol = $spec.Protocol; $p.LocalPort = $spec.Port }
    try { New-NetFirewallRule @p | Out-Null }
    catch {
        if (-not $spec.RemoteAlt) { throw }
        $p.RemoteAddress = $spec.RemoteAlt
        New-NetFirewallRule @p | Out-Null
    }
    # Read back: the fences are only as good as the rules that really exist.
    if (-not (Test-Rule $spec)) { throw "firewall rule $($spec.Name) is not in place after creating it" }
    Step "firewall: $($spec.Display)"
}
$backupOthers = Get-Others $PveAddress
$sshOthers = Get-Others $WslRange
$rules = @(
    @{ Name = 'homelab-block-direct-link'; Display = 'homelab: nothing inbound from the direct link'; Action = 'Block'; Protocol = 'Any'; Remote = @($P2pNet) },
    @{ Name = 'homelab-block-backup-vm'; Display = 'homelab: nothing inbound from the backup VM'; Action = 'Block'; Protocol = 'Any'; Remote = @($NatGuests) },
    @{ Name = 'homelab-pbs1-8007-others'; Display = "homelab: backup port $BackupPort from nobody but the hypervisor"; Action = 'Block'; Protocol = 'TCP'; Port = $BackupPort; Remote = $backupOthers.Wide; RemoteAlt = $backupOthers.Narrow },
    @{ Name = 'homelab-pbs1-ssh-others'; Display = "homelab: management port $SshForwardPort from nobody but WSL"; Action = 'Block'; Protocol = 'TCP'; Port = $SshForwardPort; Remote = $sshOthers.Wide; RemoteAlt = $sshOthers.Narrow },
    @{ Name = 'homelab-pbs1-8007'; Display = "homelab: backup port $BackupPort from the hypervisor (E14)"; Action = 'Allow'; Protocol = 'TCP'; Port = $BackupPort; Remote = @($PveAddress) }
)
if ($Manage) {
    $rules += @{ Name = 'homelab-pbs1-ssh-wsl'; Display = "homelab: management port $SshForwardPort from WSL (window open)"; Action = 'Allow'; Protocol = 'TCP'; Port = $SshForwardPort; Remote = @($WslRange) }
}
foreach ($r in $rules) { Set-Rule $r }
foreach ($r in @(Get-NetFirewallRule -Name 'homelab-*' -ErrorAction SilentlyContinue)) {
    if (@($rules | ForEach-Object { $_.Name }) -notcontains $r.Name) {
        Remove-NetFirewallRule -Name $r.Name
        Step "firewall: rule removed: $($r.Name)"
    }
}

# ---- port forwards: exactly the wanted ones on the two ports -------------------
$svc = Get-Service iphlpsvc
if ($svc.StartType -ne 'Automatic') { Set-Service iphlpsvc -StartupType Automatic; Step 'IP Helper service automatic (port forwards)' }
if ($svc.Status -ne 'Running') { Start-Service iphlpsvc; Step 'IP Helper service started' }
$forwards = @(@{ Listen = "$BackupPort"; Address = $NatPbs; Port = "$BackupPort"; What = 'backup port (E14)' })
if ($Manage) { $forwards += @{ Listen = "$SshForwardPort"; Address = $NatPbs; Port = '22'; What = 'management window: SSH from WSL' } }
$haveForwards = foreach ($line in (Invoke-Netsh interface portproxy show v4tov4)) {
    if ("$line" -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') { @{ ListenAddress = $Matches[1]; Listen = $Matches[2]; Address = $Matches[3]; Port = $Matches[4] } }
}
foreach ($h in @($haveForwards)) {
    if ($h.Listen -notin "$BackupPort", "$SshForwardPort") { continue }
    $ok = @($forwards | Where-Object { $_.Listen -eq $h.Listen -and $_.Address -eq $h.Address -and $_.Port -eq $h.Port -and $h.ListenAddress -eq '0.0.0.0' }).Count -gt 0
    if (-not $ok) {
        Invoke-Netsh interface portproxy delete v4tov4 "listenaddress=$($h.ListenAddress)" "listenport=$($h.Listen)" | Out-Null
        Step "port forward removed: $($h.ListenAddress):$($h.Listen) -> $($h.Address):$($h.Port)"
    }
}
foreach ($f in $forwards) {
    $present = @($haveForwards | Where-Object { $_.ListenAddress -eq '0.0.0.0' -and $_.Listen -eq $f.Listen -and $_.Address -eq $f.Address -and $_.Port -eq $f.Port }).Count -gt 0
    if (-not $present) {
        Invoke-Netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 "listenport=$($f.Listen)" "connectaddress=$($f.Address)" "connectport=$($f.Port)" | Out-Null
        Step "port forward $($f.Listen) -> $($f.Address):$($f.Port) ($($f.What))"
    }
}

# ---- WSL memory cap (owner decision 2026-10-06) -----------------------------
# Read and written as UTF-8 without a byte-order mark: Windows PowerShell
# would otherwise read the file in the ANSI code page and write a mark that
# WSL does not expect in front of "[wsl2]".
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $cfg) {
    $bytes = [IO.File]::ReadAllBytes($cfg)
    $hasMark = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $(if ($hasMark) { 3 } else { 0 }), $bytes.Length - $(if ($hasMark) { 3 } else { 0 }))
    $new = [regex]::Replace($text, '(?m)^[ \t]*memory[ \t]*=.*?(\r?)$', "memory=$WslMemory`$1")
    if ($new -ne $text -or $hasMark) {
        [IO.File]::WriteAllText($cfg, $new, (New-Object Text.UTF8Encoding($false)))
        Step ".wslconfig memory=$WslMemory, UTF-8 without a byte-order mark (takes effect after 'wsl --shutdown')"
    }
    if ($new -notmatch '(?m)^[ \t]*memory[ \t]*=') { Note '.wslconfig has no memory line; WSL cap not set' }
}
else { Note '.wslconfig absent; WSL cap not set' }

# ---- start after an install medium was attached ---------------------------------
if ($Iso -and (Get-VM -Name $VmName).State -eq 'Off') {
    Start-VM -Name $VmName
    Step 'vm started; an empty system disk falls through to the install medium'
}

# ---- summary ----------------------------------------------------------------
if ($changes.Count -eq 0) { Write-Host "$VmName matches the script. Nothing was changed." }
else { Write-Host "$($changes.Count) change(s)." }
if ($Manage) { Write-Host "management window: OPEN (SSH from WSL through port $SshForwardPort). Close it with a plain run when the work is done." }
else { Write-Host 'management window: closed.' }
Get-VM -Name $VmName | Select-Object Name, State, @{n = 'MemoryGB'; e = { $_.MemoryStartup / 1GB } }, ProcessorCount, AutomaticStartAction | Format-Table -AutoSize
Get-VMNetworkAdapter -VMName $VmName | Select-Object Name, SwitchName, MacAddress, IPAddresses | Format-Table -AutoSize
