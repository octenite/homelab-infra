#!/bin/bash
# Home or away, read from the hypervisor: which address does pve1 see this
# workstation connect from? No mode is stored anywhere; every guard asks
# again (docs/phases/phase-r-plan.md, "Home and away").
#
#   away-check.sh          prints home, away or unknown; exits 0, 1 or 2
#
#   away     pve1 sees the container's address: the connection came through
#            the tunnel. That is the laptop away from home, or at home with
#            Tailscale connected and the route accepted. The guards treat the
#            two alike: the message is to disconnect.
#   home     pve1 sees any other address: the direct path.
#   unknown  no answer: pve1 or the tunnel is down, or the agent holds no key.
#            Each caller decides what that means for it.
#
# Uses the SSH agent of the operator session unless SSH_AUTH_SOCK names
# another (travel.ps1 brings its own while no session is open).
set -uo pipefail

TUNNEL=10.0.30.10
HOST=${PVE_HOST:-10.0.10.10}
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"

# The variable is expanded by pve1's shell, not here.
# shellcheck disable=SC2016
conn=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "ops@$HOST" 'printf %s "$SSH_CONNECTION"' 2>/dev/null) || conn=''
client=${conn%% *}
case "$client" in
'')
	echo unknown
	exit 2
	;;
"$TUNNEL")
	echo away
	exit 1
	;;
*)
	echo home
	exit 0
	;;
esac
