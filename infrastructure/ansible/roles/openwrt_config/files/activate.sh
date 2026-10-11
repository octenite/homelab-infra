#!/bin/sh
# Runs on the OpenWrt device, detached from the SSH session.
# Reloads the services that belong to the changed configuration files.
# Usage: activate.sh <config>...   or   activate.sh all

net=0 wifi=0 fw=0 dns=0 sys=0 ssh=0 web=0 sdns=0
for c in "$@"; do
	case "$c" in
	all) net=1 fw=1 dns=1 sys=1 ssh=1 web=1 sdns=1 ;;
	network) net=1 ;;
	wireless) wifi=1 ;;
	firewall) fw=1 ;;
	dhcp) dns=1 ;;
	system) sys=1 ;;
	dropbear) ssh=1 ;;
	uhttpd) web=1 ;;
	smartdns) sdns=1 ;;
	esac
done

logger -t homelab "activating configuration: $*"

if [ "$net" -eq 1 ]; then
	# A restart rebuilds the bridge and its VLANs from scratch. It also
	# restarts Wi-Fi, so a separate Wi-Fi reload is not needed.
	/etc/init.d/network restart
	sleep 5
	fw=1
	dns=1
elif [ "$wifi" -eq 1 ]; then
	wifi reload
fi
if [ "$fw" -eq 1 ]; then
	# Reload, not restart. On this release a restart deletes the rule table
	# and then renders and loads the new one, so for the length of one
	# render (about half a second here) the router filters nothing between
	# its networks. A reload replaces the table in one step. Chains of a
	# zone that no longer exists stay behind empty, with nothing jumping to
	# them, until the next boot.
	/etc/init.d/firewall reload
	# A reload needs a firewall that is running. Without a loaded table,
	# start it.
	nft list table inet fw4 >/dev/null 2>&1 || /etc/init.d/firewall restart
fi
if [ "$dns" -eq 1 ]; then
	/etc/init.d/dnsmasq restart
	/etc/init.d/odhcpd restart
fi
[ "$sdns" -eq 1 ] && /etc/init.d/smartdns restart
if [ "$sys" -eq 1 ]; then
	/etc/init.d/system reload
	/etc/init.d/sysntpd restart
fi
[ "$web" -eq 1 ] && /etc/init.d/uhttpd restart
[ "$ssh" -eq 1 ] && /etc/init.d/dropbear restart

logger -t homelab "activation finished"
exit 0
