#!/bin/bash
# Compares the container template on the hypervisor with the pin in Git.
# The API cannot do it: it returns a size and a change time, never a digest.
# So the operator's SSH login reads the checksum on the host. Called by
# run.sh before a plan or an apply of the root "remote", and by child.sh
# after an apply. It fails closed: no answer is a refusal. It only reports;
# what follows from a failure is the caller's to say.
#
# Limit: whoever holds the OpenTofu token may replace the file after this
# check and put the original back later (exception X33, backlog B43).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PIN="$REPO/infrastructure/opentofu/roots/remote/template.auto.tfvars.json"
HOST=${PVE_HOST:-10.0.10.10}
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"

read -r file want < <(python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(d["template_file"], d["template_sha512"])' "$PIN")
[[ $file =~ ^[A-Za-z0-9._-]+$ && $want =~ ^[0-9a-f]{128}$ ]] || {
	echo "template pin unreadable: $PIN" >&2
	exit 1
}
# Exit codes: 1 the file is missing or is not the pinned one; 3 it could not
# be checked. With pipefail the pipeline's status is ssh's, and ssh answers
# 255 for a failure of its own.
got=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "ops@$HOST" sha512sum -- "/var/lib/vz/template/cache/$file" | cut -d' ' -f1) || {
	rc=$?
	if [ "$rc" -eq 255 ]; then
		echo "the hypervisor did not answer over SSH: the template could not be compared with its pin" >&2
		exit 3
	fi
	echo "template $file is missing or unreadable on $HOST" >&2
	exit 1
}
[ "$got" = "$want" ] || {
	echo "template $file on $HOST is not the pinned one (got ${got:-nothing})" >&2
	exit 1
}
