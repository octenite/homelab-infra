#!/bin/bash
# The one login of a remote-access container to the tailnet (Phase R, step
# R.8; docs/runbooks/tailnet-setup.md, section 4). Run by the owner, in their
# own terminal, at home, with a session open:
#
#   scripts/ops/remote-login.sh            (or: just remote-login)
#
# It refuses unless the container's daemon says it needs a login (every login
# creates a new device), then runs `tailscale up` on the container with every
# setting named. The browser address appears here; the owner opens it on the
# laptop and signs in with GitHub. The container is then logged in but locked
# out: the script prints the signing command for the laptop.
#
# Nothing of this is Ansible's: the login needs a person at a browser, and
# the signature needs the laptop, the only signer.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=10.0.30.10
ALIAS=remote1
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o "HostKeyAlias=$ALIAS" "ops@$HOST")
TAG=$(sed -n 's/^remote_ct_tailscale_tag:[[:space:]]*//p' "$REPO/infrastructure/ansible/playbooks/group_vars/remote.yaml")
ROUTES=$(sed -n 's/^remote_ct_tailscale_routes:[[:space:]]*\[\(.*\)\]/\1/p' "$REPO/infrastructure/ansible/playbooks/group_vars/remote.yaml" | tr -d ' ')
NAME=$(sed -n 's/^remote_ct_tailscale_hostname:[[:space:]]*//p' "$REPO/infrastructure/ansible/playbooks/group_vars/remote.yaml")
[ -n "$TAG" ] && [ -n "$ROUTES" ] && [ -n "$NAME" ] || {
	echo "the tag, the routes or the host name could not be read from group_vars/remote.yaml" >&2
	exit 1
}
[ -r /dev/shm/homelab-session/age.key ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}

state=$("${SSH[@]}" sudo tailscale status --json --peers=false 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["BackendState"])') || {
	echo "the container's daemon did not answer; is the container running and configured (just remote-start, just remote-apply)?" >&2
	exit 1
}
[ "$state" = NeedsLogin ] || {
	echo "the container is '$state', not 'NeedsLogin': it is logged in already, or a login is pending. Every login creates a new device. Nothing was done." >&2
	exit 1
}

cat <<EOF
A browser address follows. Open it on the laptop and sign in with GitHub.
The container joins the tailnet with the tag $TAG and the route $ROUTES, and
is locked out until the laptop signs it. Up to ten minutes.

EOF
# -t: the daemon prints the address on the terminal and waits for the login.
ssh -t -o "HostKeyAlias=$ALIAS" "ops@$HOST" sudo tailscale up \
	"--advertise-tags=$TAG" "--advertise-routes=$ROUTES" "--hostname=$NAME" \
	--accept-dns=false --accept-routes=false --ssh=false --advertise-exit-node=false \
	--timeout=10m || echo "tailscale up ended with an error; read the lines above" >&2

echo
echo "== the container's own words"
"${SSH[@]}" sudo tailscale lock status || true
echo
cat <<'EOF'
== next, on the laptop (connected: tray "Connect" or a bare `tailscale up`, routes NOT accepted)
   1. tailscale lock status        lists the node as locked out, with its node key
   2. compare that key with the one printed above
   3. run the `tailscale lock sign nodekey:... tlpub:...` line printed above
   4. tailscale down
Then, back here: just remote-apply (it must change nothing), just test-remote layers.
EOF
