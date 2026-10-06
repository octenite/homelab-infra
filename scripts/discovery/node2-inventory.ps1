# Read-only inventory of Node 2 (the Windows workstation) for the backup
# server design. Run in an elevated PowerShell; Hyper-V queries need it.
# Output goes to the private repository; nothing here changes the system.
#
#   powershell -ExecutionPolicy Bypass -File scripts\discovery\node2-inventory.ps1

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$out = Join-Path $repo 'private\inventory\node2.txt'

function Section($name) { "`n===== $name =====" }

$report = @()
$report += "node2 inventory, $(Get-Date -Format 'yyyy-MM-dd HH:mm') local"
$report += "elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

$report += Section 'os'
$report += (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime | Format-List | Out-String).Trim()
$report += (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Select-Object DisplayVersion, CurrentBuild, UBR | Format-List | Out-String).Trim()
$report += "insider: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' -ErrorAction SilentlyContinue).BranchName)"

$report += Section 'hardware'
$report += (Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, TotalPhysicalMemory, NumberOfLogicalProcessors | Format-List | Out-String).Trim()
$report += (Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, VirtualizationFirmwareEnabled | Format-List | Out-String).Trim()

$report += Section 'memory now'
$os = Get-CimInstance Win32_OperatingSystem
$report += "total MiB: $([int]($os.TotalVisibleMemorySize / 1024))  free MiB: $([int]($os.FreePhysicalMemory / 1024))"

$report += Section 'disks and volumes'
$report += (Get-Disk | Select-Object Number, FriendlyName, BusType, @{n = 'SizeGB'; e = { [int]($_.Size / 1GB) } }, PartitionStyle, HealthStatus | Format-Table -AutoSize | Out-String).Trim()
$report += (Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel, FileSystem, @{n = 'SizeGB'; e = { [int]($_.Size / 1GB) } }, @{n = 'FreeGB'; e = { [int]($_.SizeRemaining / 1GB) } } | Format-Table -AutoSize | Out-String).Trim()
$report += (Get-Partition | Where-Object DriveLetter | Select-Object DriveLetter, DiskNumber | Format-Table -AutoSize | Out-String).Trim()

$report += Section 'bitlocker'
$report += (Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object MountPoint, ProtectionStatus, VolumeStatus | Format-Table -AutoSize | Out-String).Trim()

$report += Section 'hyper-v feature'
$report += (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All, Microsoft-Hyper-V, Microsoft-Hyper-V-Management-PowerShell, VirtualMachinePlatform, Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue | Select-Object FeatureName, State | Format-Table -AutoSize | Out-String).Trim()
$report += "vmms service: $((Get-Service vmms -ErrorAction SilentlyContinue).Status)"

$report += Section 'hyper-v vms'
$report += (Get-VM -ErrorAction SilentlyContinue | Select-Object Name, State, Generation, @{n = 'MemGB'; e = { [int]($_.MemoryAssigned / 1GB) } }, @{n = 'StartupGB'; e = { [int]($_.MemoryStartup / 1GB) } }, ProcessorCount, Path, AutomaticStartAction, Version | Format-Table -AutoSize | Out-String).Trim()
$report += (Get-VM -ErrorAction SilentlyContinue | Get-VMHardDiskDrive | Select-Object VMName, Path | Format-Table -AutoSize | Out-String).Trim()
$report += (Get-VM -ErrorAction SilentlyContinue | Get-VMNetworkAdapter | Select-Object VMName, SwitchName, MacAddress | Format-Table -AutoSize | Out-String).Trim()

$report += Section 'hyper-v switches'
$report += (Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object Name, SwitchType, NetAdapterInterfaceDescription, AllowManagementOS | Format-Table -AutoSize | Out-String).Trim()

$report += Section 'network adapters'
$report += (Get-NetAdapter -IncludeHidden:$false | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress | Format-Table -AutoSize | Out-String).Trim()
$report += (Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match '2.5|UE302|Realtek USB|RTL8156' } | Select-Object FriendlyName, Status, Present | Format-Table -AutoSize | Out-String).Trim()

$report += Section 'power and uptime'
$report += "uptime: $((Get-Date) - $os.LastBootUpTime)"
$report += (powercfg /getactivescheme | Out-String).Trim()
$report += "boots in the last 30 days:"
$report += (Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 6005; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | Select-Object -ExpandProperty TimeCreated | ForEach-Object { $_.ToString('yyyy-MM-dd HH:mm') } | Out-String).Trim()
$report += "sleep/hibernate entries (Kernel-Power 42) in the last 30 days: $((Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 42; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue | Measure-Object).Count)"

$report += Section 'windows update'
$report += (Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, InstalledOn | Format-Table -AutoSize | Out-String).Trim()

$report += Section 'wsl'
$report += (wsl --list --verbose 2>&1 | Out-String).Trim()
$cfg = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path $cfg) { $report += "`.wslconfig:"; $report += (Get-Content $cfg | Out-String).Trim() } else { $report += '.wslconfig: absent' }

$report += Section 'firewall profiles'
$report += (Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction | Format-Table -AutoSize | Out-String).Trim()

New-Item -ItemType Directory -Force (Split-Path -Parent $out) | Out-Null
$report -join "`n" | Out-File -FilePath $out -Encoding utf8
Write-Host "written: $out"
