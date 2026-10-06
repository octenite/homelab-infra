#!/bin/bash
# Run one Ansible playbook with the operator session's environment.
#
#   play.sh <playbook name without .yaml> [ansible-playbook arguments...]
#
# Ansible ignores an ansible.cfg in a world-writable directory (the working
# copy is on a Windows drive), so the configuration is named explicitly.
set -euo pipefail

playbook=${1:?playbook name, for example pve}
shift
REPO=$(cd "$(dirname "$0")/../.." && pwd)
[ -r /dev/shm/homelab-session/age.key ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}
cd "$REPO/infrastructure/ansible"
[ -f "playbooks/$playbook.yaml" ] || {
	echo "no such playbook: playbooks/$playbook.yaml" >&2
	exit 2
}
export ANSIBLE_CONFIG="$PWD/ansible.cfg"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
exec ansible-playbook "playbooks/$playbook.yaml" "$@"
