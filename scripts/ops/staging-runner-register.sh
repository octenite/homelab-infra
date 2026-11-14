#!/bin/bash
# Registers the GitHub Actions runner on the staging machine. Run by the
# owner, in their own terminal, at home, with a session open:
#
#   scripts/ops/staging-runner-register.sh        (or: just staging-runner-register)
#
# GitHub hands out a registration token that is valid for one hour: in the
# organisation's (or the repository's) Settings, Actions, Runners, "New
# self-hosted runner". It is typed at a hidden prompt here, travels to the
# machine on standard input and is used once; it is stored nowhere. What the
# runner keeps afterwards is its own credential, in its directory on the
# machine.
#
# Nothing of this is Ansible's: the token needs a person at GitHub.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=10.0.40.10
ALIAS=stg1
VARS="$REPO/infrastructure/ansible/playbooks/group_vars/staging.yaml"
TEAM="$REPO/private/ansible/inventory/host_vars/stg1/team.yaml"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o "HostKeyAlias=$ALIAS" "ops@$HOST")

var() { # <file> <name> : the value of a top-level "name: value" line
	sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n 1
}
DIR=$(var "$VARS" staging_vm_runner_dir)
USER_NAME=$(var "$VARS" staging_vm_runner_user)
LABELS=$(var "$VARS" staging_vm_runner_labels)
URL=$(var "$TEAM" staging_vm_runner_url)
[[ $DIR =~ ^/[A-Za-z0-9/_-]+$ && $USER_NAME =~ ^[a-z][a-z0-9_-]*$ && $LABELS =~ ^[A-Za-z0-9,_-]+$ ]] || {
	echo "the runner's directory, user or labels could not be read from $VARS" >&2
	exit 1
}
[[ $URL =~ ^https://github\.com/[A-Za-z0-9._/-]+$ ]] || {
	echo "staging_vm_runner_url is missing or not a GitHub address in $TEAM" >&2
	exit 1
}

if "${SSH[@]}" sudo test -e "$DIR/.runner"; then
	echo "the runner is registered already. To register it again, remove it at GitHub first, then on the machine: sudo systemctl stop actions-runner; sudo rm $DIR/.runner $DIR/.credentials $DIR/.credentials_rsaparams" >&2
	exit 1
fi
"${SSH[@]}" sudo test -x "$DIR/config.sh" || {
	echo "the runner is not installed on the machine; run 'just staging-apply' first" >&2
	exit 1
}

echo "Registering at: $URL"
read -r -s -p "Registration token from GitHub (hidden, valid one hour): " TOKEN
echo
[[ $TOKEN =~ ^[A-Z0-9]{20,64}$ ]] || {
	echo "that does not look like a registration token (capital letters and digits); nothing was done" >&2
	exit 1
}

# The command travels on standard input, so the token is in no argument list
# on this side. On the machine it is an argument of the vendor's script for
# the seconds that script runs.
"${SSH[@]}" sudo -u "$USER_NAME" bash -s <<EOF
set -euo pipefail
cd '$DIR'
./config.sh --unattended --url '$URL' --token '$TOKEN' --name stg1 --labels '$LABELS' --work _work --replace
EOF
unset TOKEN

"${SSH[@]}" sudo systemctl start actions-runner
sleep 5
"${SSH[@]}" sudo systemctl is-active actions-runner
echo "Registered. The runner appears at GitHub as 'stg1' with the label '$LABELS'; a workflow asks for it with: runs-on: [self-hosted, $LABELS]"
