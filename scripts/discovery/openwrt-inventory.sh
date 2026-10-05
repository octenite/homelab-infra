#!/bin/sh
# Read-only inventory of an OpenWrt device (router or access point).
#
# It changes nothing: no uci set, no commit, no service restart, no package
# install. Wi-Fi keys, passwords and other secret values are redacted before
# they are printed. /etc/shadow is never read.
#
# The output still contains MAC addresses, SSIDs and host names, so it belongs
# in the private repository, never in the public one.
#
# Run from the operator workstation; the script is piped to the device:
#   ssh root@<device> 'sh -s' < scripts/discovery/openwrt-inventory.sh > <private path>/<device>.txt

set -u

section() {
	printf '\n===== %s =====\n' "$1"
}

# Replace the value of any option whose name looks like a secret.
redact() {
	sed -E "s/^([^=]*\.(key[0-9]?|sae_password|password|psk|private_key|preshared_key|secret|token|auth_secret|pppoe_pass|radius_secret|wps_pin))=.*/\1='<redacted>'/"
}

show() {
	uci -q show "$1" | redact
}

section "release"
cat /etc/openwrt_release 2>/dev/null
cat /etc/openwrt_version 2>/dev/null

section "board"
cat /tmp/sysinfo/board_name 2>/dev/null
cat /tmp/sysinfo/model 2>/dev/null
ubus call system board 2>/dev/null

section "uptime and memory"
uptime
free

section "storage"
df -h

section "package manager and installed packages"
if command -v apk >/dev/null 2>&1; then
	echo "manager: apk"
	apk list --installed 2>/dev/null | sort
elif command -v opkg >/dev/null 2>&1; then
	echo "manager: opkg"
	opkg list-installed 2>/dev/null | sort
fi

section "uci network"
show network

section "uci wireless (secrets redacted)"
show wireless

section "uci dhcp"
show dhcp

section "uci firewall"
show firewall

section "uci system"
show system

section "uci dropbear"
show dropbear

section "uci uhttpd"
show uhttpd

section "links and addresses"
ip -br link 2>/dev/null || ip link
ip -br addr 2>/dev/null || ip addr

section "bridge vlan table"
bridge vlan show 2>/dev/null

section "routes"
ip route
ip -6 route 2>/dev/null

section "wan status (address range matters: is it inside 100.64.0.0/10?)"
ifstatus wan 2>/dev/null
ifstatus wan6 2>/dev/null

section "time service"
show system | grep -i ntp
pgrep -a ntpd 2>/dev/null
pgrep -a chronyd 2>/dev/null

section "listening sockets"
netstat -lntu 2>/dev/null

section "authorized ssh keys (count only)"
if [ -f /etc/dropbear/authorized_keys ]; then
	wc -l </etc/dropbear/authorized_keys
else
	echo 0
fi

section "wifi radios and clients (count only)"
iwinfo 2>/dev/null | grep -E 'ESSID|Channel|Hardware|Mode'
for ifc in $(iwinfo 2>/dev/null | awk '/ESSID/ {print $1}'); do
	printf '%s clients: ' "$ifc"
	iwinfo "$ifc" assoclist 2>/dev/null | grep -c 'dBm'
done

section "flash layout"
cat /proc/mtd 2>/dev/null

section "done"
date -u
