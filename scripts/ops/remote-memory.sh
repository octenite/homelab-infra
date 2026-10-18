#!/bin/bash
# Memory of the administration container remote1, read on pve1 from its
# cgroup: drill 5 of docs/phases/phase-r-plan.md, under D12 (the container
# runs only while the laptop is away, so the week is summed over trips).
#
#   remote-memory.sh            (or: just remote-memory)  one reading
#   remote-memory.sh sample N   the highest working set over N seconds, read every second
#   remote-memory.sh window     the same until Enter, and memory.peak over that window alone
#
# Read-only. `window` resets memory.peak for its own file descriptor only,
# which every other reader of the file does not see (Linux 6.12 and later).
#
# The working set is memory.current less the inactive page cache: what the
# container cannot give back under pressure. A reading holds it at that
# moment only (ws_now=); its highest value over a span, such as an update
# run, comes from `sample` or `window`. memory.peak counts page cache too, so
# it is an upper bound; it starts again with every start of the container.
#
# The last line of a reading is one record. travel.ps1 -Home reads it before
# it stops the container and appends it to C:\ProgramData\homelab\
# remote1-memory.log once the stop succeeded (docs/components/travel-mode.md).
# pid= names the container's start: of several lines with the same pid only
# the last counts.
set -uo pipefail

VMID=3010
PVE=10.0.10.10
CG=/sys/fs/cgroup/lxc/$VMID
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
pve() { ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 "ops@$PVE" "$@"; }
mib() { echo $(($1 / 1048576)); }

# The loop of `sample` and `window`, in perl on pve1 (Proxmox's own tools are
# perl, so it is always there). Arguments: the cgroup, then a number of
# seconds, or "window". It reads memory.peak again through the descriptor it
# reset, which a shell cannot do.
# shellcheck disable=SC2016  # perl's variables
LOOP='use strict; use warnings; use IO::Select; $| = 1;
my ($cg, $mode) = @ARGV;
sub slurp { open(my $f, "<", $_[0]) or return undef; local $/; my $v = <$f>; return $v }
open(my $pk, "+<", "$cg/memory.peak") or die "no cgroup $cg: is remote1 running?\n";
my $reset = $mode eq "window" ? defined(syswrite($pk, "reset\n")) : 0;
if ($mode eq "window") { print STDERR $reset ? "memory.peak reset for this window. Press Enter to end it.\n" : "memory.peak cannot be reset here: only the sampled working set counts. Press Enter to end it.\n" }
my $sel = IO::Select->new(\*STDIN);
my ($max, $at, $n, $end) = (0, "-", 0, time + ($mode eq "window" ? 86400 : $mode));
while (time < $end) {
  my $cur = slurp("$cg/memory.current"); my $st = slurp("$cg/memory.stat");
  last unless defined $cur and defined $st;
  my ($in) = $st =~ /^inactive_file (\d+)$/m; my $ws = $cur - ($in // 0); $n++;
  if ($ws > $max) { $max = $ws; my @t = localtime; $at = sprintf("%02d:%02d:%02d", @t[2, 1, 0]) }
  if ($mode eq "window") { last if $sel->can_read(1) } else { sleep 1 }
}
my $peak = "-";
if ($reset) { sysseek($pk, 0, 0); my $b = ""; sysread($pk, $b, 64); chomp $b; $peak = $b if length $b }
print "max_ws $max $at $n\nwindow_peak $peak\n";'

case "${1:-read}" in
read)
	# shellcheck disable=SC2029  # the cgroup and the id are expanded here
	r=$(
		pve "sudo bash -s -- $CG $VMID" 2>/dev/null <<'EOF'
cg=$1 id=$2
[ -r "$cg/memory.current" ] || { echo none; exit 3; }
st=$(pct status "$id" --verbose)
up=$(sed -n 's/^uptime: //p' <<<"$st")
echo "up $up"
echo "pid $(sed -n 's/^pid: //p' <<<"$st")"
echo "current $(cat "$cg/memory.current")"
echo "peak $(cat "$cg/memory.peak")"
echo "max $(cat "$cg/memory.max")"
awk '$1 == "anon" || $1 == "file" || $1 == "inactive_file" { print $1, $2 }' "$cg/memory.stat"
awk '{ print "ev_" $1, $2 }' "$cg/memory.events"
# unattended-upgrade writes its log on every run, also when it finds nothing;
# apt's daily script skips it when it ran the same day, so the service's own
# exit time would not say it ran.
log=$(pct exec "$id" -- stat -c %Y /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null)
if [ -n "$log" ] && [ -n "$up" ] && [ "$log" -ge $(($(date +%s) - up)) ]; then echo "update yes"; else echo "update no"; fi
EOF
	)
	rc=$?
	if [ "$rc" -eq 3 ] || [ "$r" = none ]; then
		echo "remote1 is not running: no cgroup to read"
		exit 3
	fi
	v() { sed -n "s/^$1 //p" <<<"$r" | head -n 1; }
	if [ -z "$(v current)" ]; then
		echo "pve1 did not answer: no reading"
		exit 1
	fi
	ws=$(($(v current) - $(v inactive_file)))
	max=$(v max)
	[ "$max" = max ] || max=$(mib "$max")
	echo "remote1 memory, $(date '+%Y-%m-%d %H:%M %Z'):"
	echo "  running for:          $(v up) s (this start: init pid $(v pid))"
	echo "  working set now:      $(mib "$ws") MiB (memory.current less the inactive page cache; not a peak)"
	echo "  current, peak:        $(mib "$(v current)") MiB, $(mib "$(v peak)") MiB (the peak since this start, with page cache)"
	echo "  limit:                $max MiB"
	echo "  anon, file:           $(mib "$(v anon)") MiB, $(mib "$(v file)") MiB"
	echo "  at the limit, oom kills: $(v ev_max), $(v ev_oom_kill)"
	echo "  an update run in this start: $(v update)"
	echo "remote1-memory $(date -u '+%Y-%m-%dT%H:%M:%SZ') pid=$(v pid) up=$(v up) ws_now=$(mib "$ws") current=$(mib "$(v current)") peak=$(mib "$(v peak)") limit=$max anon=$(mib "$(v anon)") file=$(mib "$(v file)") max_events=$(v ev_max) oom_kill=$(v ev_oom_kill) update=$(v update)"
	;;
sample | window)
	mode=window
	if [ "$1" = sample ]; then
		mode=${2:-}
		if ! [[ $mode =~ ^[0-9]+$ ]]; then
			echo "usage: $0 sample <seconds>" >&2
			exit 2
		fi
		echo "Sampling remote1's working set every second for $mode s ..."
	fi
	# shellcheck disable=SC2029  # assembled here, run there
	out=$(pve "sudo perl -e $(printf '%q' "$LOOP") $CG $mode")
	rc=$?
	read -r _ max at n < <(grep '^max_ws ' <<<"$out")
	peak=$(sed -n 's/^window_peak //p' <<<"$out")
	if [ "$rc" -ne 0 ] || [ -z "${n:-}" ]; then
		echo "no reading: ${out:-pve1 did not answer}"
		exit 1
	fi
	echo "highest working set: $(mib "$max") MiB at $at ($n readings)"
	[ "$peak" = - ] || echo "memory.peak over the window: $(mib "$peak") MiB"
	;;
*)
	echo "usage: $0 [read|sample <seconds>|window]" >&2
	exit 2
	;;
esac
