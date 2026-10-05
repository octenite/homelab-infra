#!/bin/sh
# Read-only inventory of the existing Proxmox VE host (Node 1) before it is
# reinstalled.
#
# It changes nothing: no package install, no configuration change, no guest
# start or stop. Purpose: replace spec-sheet values in docs/INITIAL-ASSESSMENT.md
# with measured ones, and list every guest and volume so nothing is wiped by
# surprise.
#
# The output contains MAC addresses, serial numbers and guest names, so it
# belongs in the private repository, never in the public one.
#
# Run from the operator workstation; the script is piped to the host:
#   ssh root@<node1> 'sh -s' < scripts/discovery/pve-inventory.sh > <private path>/node1.txt

set -u

section() {
	printf '\n===== %s =====\n' "$1"
}

have() {
	command -v "$1" >/dev/null 2>&1
}

section "proxmox and kernel"
have pveversion && pveversion -v | head -n 5
uname -a
cat /etc/debian_version 2>/dev/null

section "boot mode"
if [ -d /sys/firmware/efi ]; then echo "UEFI"; else echo "legacy BIOS"; fi

section "board and firmware"
if have dmidecode; then
	for key in system-manufacturer system-product-name baseboard-manufacturer baseboard-product-name baseboard-version bios-vendor bios-version bios-release-date; do
		printf '%s: ' "$key"
		dmidecode -s "$key" 2>/dev/null
	done
	dmidecode -t memory 2>/dev/null | grep -E 'Size:|Type:|Speed:|Locator:|Maximum Capacity|Number Of Devices'
fi

section "cpu"
lscpu 2>/dev/null | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|Virtualization|Flags' | sed -E 's/^(Flags:).*/\1 (see next lines)/'
for flag in vmx ept aes avx avx2 sse4_2 popcnt cx16; do
	if grep -qw "$flag" /proc/cpuinfo; then echo "flag $flag: yes"; else echo "flag $flag: no"; fi
done
grep -m1 microcode /proc/cpuinfo

section "cpu vulnerabilities"
grep -r . /sys/devices/system/cpu/vulnerabilities/ 2>/dev/null

section "iommu"
dmesg 2>/dev/null | grep -i -E 'DMAR|IOMMU' | head -n 10

section "memory (the figure the RAM budget is re-based on)"
free -m
grep -E 'MemTotal|MemAvailable|SwapTotal' /proc/meminfo
cat /sys/kernel/mm/ksm/run 2>/dev/null

section "block devices"
lsblk -o NAME,SIZE,TYPE,ROTA,TRAN,MODEL,FSTYPE,MOUNTPOINT 2>/dev/null

section "smart"
if have smartctl; then
	for disk in /dev/sd? /dev/nvme?n?; do
		[ -e "$disk" ] || continue
		echo "--- $disk"
		smartctl -i -H -A "$disk" 2>/dev/null | grep -v -i 'serial number'
	done
fi

section "storage layout"
df -h -x tmpfs -x devtmpfs
have pvs && pvs 2>/dev/null
have vgs && vgs 2>/dev/null
have lvs && lvs 2>/dev/null
have zpool && zpool status 2>/dev/null
have pvesm && pvesm status 2>/dev/null

section "pci devices of interest"
lspci -nn 2>/dev/null | grep -i -E 'ethernet|network|sata|ahci|usb|vga'

section "usb devices"
have lsusb && lsusb

section "network interfaces"
ip -br link
ip -br addr
cat /etc/network/interfaces 2>/dev/null

section "link speed and driver per physical nic"
for path in /sys/class/net/*; do
	nic=$(basename "$path")
	[ -e "$path/device" ] || continue
	echo "--- $nic"
	if have ethtool; then
		ethtool "$nic" 2>/dev/null | grep -E 'Speed|Duplex|Link detected'
		ethtool -i "$nic" 2>/dev/null | grep -E 'driver|version|bus-info'
	fi
done

section "guests (everything listed here is destroyed by the reinstall)"
have qm && qm list 2>/dev/null
have pct && pct list 2>/dev/null

section "guest volumes"
if have pvesm; then
	for store in $(pvesm status 2>/dev/null | awk 'NR>1 {print $1}'); do
		echo "--- $store"
		pvesm list "$store" 2>/dev/null
	done
fi

section "cluster, users and tokens (names only)"
have pvecm && pvecm status 2>/dev/null | head -n 12
have pveum && pveum user list 2>/dev/null
have pveum && pveum user token list root@pam 2>/dev/null

section "backup jobs and firewall state"
cat /etc/pve/jobs.cfg 2>/dev/null
have pve-firewall && pve-firewall status 2>/dev/null

section "time"
timedatectl 2>/dev/null
have chronyc && chronyc sources 2>/dev/null

section "uptime and load"
uptime

section "done"
date -u
