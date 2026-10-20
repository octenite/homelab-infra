#!/bin/sh
# The end of the backup server's nightly window (backlog B51). Run every two
# minutes from 03:00 to 05:58 by homelab-night-off.timer; it acts from 03:30.
# Powers the VM off when ALL of these hold, and stays up on anything else,
# an error or an unreadable answer included:
#   - this boot was the nightly window's: between 02:05 and 03:20 today (a VM
#     started by hand at another time is never powered off);
#   - no task runs on the server (a backup, a restore, GC, prune, verify);
#   - no package run: the apt and update timers' services are idle, no dpkg or
#     apt process exists;
#   - nobody is logged in (the management window's SSH sessions count);
#   - /run/homelab/stay-up does not exist (touch it to keep the VM up).
# The workstation's task shuts the VM down at 06:30 if it is still up.
#
#   homelab-night-off            as the timer runs it
#   homelab-night-off --dry-run  prints the decision, powers nothing off
set -u

dry=no
[ "${1:-}" = --dry-run ] && dry=yes

stay() {
	if [ "$dry" = yes ]; then echo "stay up: $*"; else logger -t homelab "night-off: staying up: $*"; fi
	exit 0
}

now=$(date +%s)
day=$(date +%F)
at() { date -d "$day $1" +%s; }

[ "$now" -ge "$(at 03:30)" ] || stay "before 03:30"
boot=$(awk '/^btime/ { print $2 }' /proc/stat)
case "$boot" in '' | *[!0-9]*) stay "boot time unreadable" ;; esac
if [ "$boot" -lt "$(at 02:05)" ] || [ "$boot" -gt "$(at 03:20)" ]; then
	stay "not started by the nightly window (booted $(date -d "@$boot" '+%F %R'))"
fi
[ ! -e /run/homelab/stay-up ] || stay "/run/homelab/stay-up exists"

# Without --all the list holds the running tasks only.
tasks=$(timeout 60 proxmox-backup-manager task list --output-format json 2>/dev/null) || stay "the task list could not be read"
n=$(printf '%s' "$tasks" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null) || stay "the task list could not be parsed"
[ "$n" = 0 ] || stay "$n task(s) running"

for u in apt-daily.service apt-daily-upgrade.service proxmox-backup-daily-update.service; do
	s=$(systemctl show -P ActiveState "$u" 2>/dev/null) || stay "the state of $u could not be read"
	case "$s" in activating | active | deactivating | reloading) stay "$u is $s" ;; esac
done
# Not the unattended-upgrades shutdown helper, which runs all the time: only
# the upgrade itself (it also runs inside apt-daily-upgrade.service, above).
! pgrep -x 'dpkg|apt|apt-get' >/dev/null || stay "a package run is in progress"
! pgrep -f '/usr/bin/unattended-upgrade( |$)' >/dev/null || stay "unattended-upgrade is running"

sessions=$(loginctl list-sessions --no-legend 2>/dev/null) || stay "the sessions could not be read"
[ -z "$sessions" ] || stay "someone is logged in"

if [ "$dry" = yes ]; then
	echo "power off: idle, booted by the nightly window at $(date -d "@$boot" '+%R')"
	exit 0
fi
logger -t homelab "night-off: idle; powering off (booted by the nightly window at $(date -d "@$boot" '+%R'))"
systemctl poweroff
