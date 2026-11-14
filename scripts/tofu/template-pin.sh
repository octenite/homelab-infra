#!/bin/bash
# Compares the image a root builds its guest from, on the hypervisor, with the
# pin in Git: the container template of the root "remote" (the default), or
# the cloud image of the root "staging".
#
#   template-pin.sh [remote|staging]
#
# The API cannot do it: it returns a size and a change time, never a digest.
# So the operator's SSH login reads the checksum on the host. Called by
# run.sh before a plan or an apply of those roots, and by child.sh after an
# apply. It fails closed: no answer is a refusal. It only reports; what
# follows from a failure is the caller's to say.
#
# Limit: whoever holds the OpenTofu token may replace the file after this
# check and put the original back later (exception X33, backlog B43).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
case "${1:-remote}" in
remote)
	PIN="$REPO/infrastructure/opentofu/roots/remote/template.auto.tfvars.json"
	KEY=template
	DIR=/var/lib/vz/template/cache
	;;
staging)
	PIN="$REPO/infrastructure/opentofu/roots/staging/image.auto.tfvars.json"
	KEY=image
	DIR=/var/lib/vz/import
	;;
*)
	echo "usage: $0 [remote|staging]" >&2
	exit 2
	;;
esac
HOST=${PVE_HOST:-10.0.10.10}
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"

read -r file want < <(python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(d[sys.argv[2] + "_file"], d[sys.argv[2] + "_sha512"])' "$PIN" "$KEY")
[[ $file =~ ^[A-Za-z0-9._-]+$ && $want =~ ^[0-9a-f]{128}$ ]] || {
	echo "$KEY pin unreadable: $PIN" >&2
	exit 1
}
# Exit codes: 1 the file is missing or is not the pinned one; 3 it could not
# be checked. With pipefail the pipeline's status is ssh's, and ssh answers
# 255 for a failure of its own.
got=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "ops@$HOST" sha512sum -- "$DIR/$file" | cut -d' ' -f1) || {
	rc=$?
	if [ "$rc" -eq 255 ]; then
		echo "the hypervisor did not answer over SSH: the $KEY could not be compared with its pin" >&2
		exit 3
	fi
	echo "$KEY $file is missing or unreadable on $HOST" >&2
	exit 1
}
[ "$got" = "$want" ] || {
	echo "$KEY $file on $HOST is not the pinned one (got ${got:-nothing})" >&2
	exit 1
}
