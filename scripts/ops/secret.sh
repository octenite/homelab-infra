#!/bin/bash
# Read and write single values in the private repository's SOPS files with
# the open operator session.
#
#   secret.sh reveal <file> [key [subkey]]   print one value, or the whole file
#   secret.sh set <file> <key>               store a value typed at a hidden prompt
#
# set: the value never appears on a command line (the process list would
# show it) and never touches a disk in the clear; a failure leaves neither a
# plaintext file nor a half-written target behind. The file is created when
# it does not exist.
set -euo pipefail
umask 077

KEY=/dev/shm/homelab-session/age.key
need_session() {
	[ -r "$KEY" ] || {
		echo "No key session open. Run 'just session-start' first." >&2
		exit 1
	}
	export SOPS_AGE_KEY_FILE=$KEY
}

cmd=${1:-}
file=${2:-}
case "$cmd" in
reveal)
	[ -n "$file" ] || {
		echo "usage: $0 reveal <file> [key [subkey]]" >&2
		exit 2
	}
	need_session
	if [ -n "${4:-}" ]; then
		sops decrypt --extract "[\"$3\"][\"$4\"]" "$file"
		echo
	elif [ -n "${3:-}" ]; then
		sops decrypt --extract "[\"$3\"]" "$file"
		echo
	else
		sops decrypt "$file"
	fi
	;;
set)
	key=${3:-}
	[ -n "$file" ] && [ -n "$key" ] || {
		echo "usage: $0 set <file> <key>" >&2
		exit 2
	}
	case "$file" in
	private/*.sops.yaml) ;;
	*)
		echo "the file must be private/....sops.yaml" >&2
		exit 1
		;;
	esac
	read -rsp "value for $key: " value
	echo
	[ -n "$value" ] || {
		echo "empty value, nothing stored" >&2
		exit 1
	}
	json=$(printf '%s' "$value" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
	unset value
	if [ -s "$file" ]; then
		need_session
		printf '%s' "$json" | sops set --value-stdin "$file" "[\"$key\"]"
	else
		rel=${file#private/}
		work=$(mktemp -d /dev/shm/homelab-secret.XXXXXX)
		trap 'rm -rf "$work"' EXIT
		printf '%s: %s\n' "$key" "$json" >"$work/plain.yaml"
		mkdir -p "$(dirname "$file")"
		(cd private && sops encrypt --filename-override "$rel" "$work/plain.yaml") >"$work/encrypted.yaml"
		[ -s "$work/encrypted.yaml" ]
		mv "$work/encrypted.yaml" "$file"
	fi
	unset json
	echo "stored $key in $file; commit the private repository"
	;;
*)
	echo "usage: $0 reveal <file> [key [subkey]] | set <file> <key>" >&2
	exit 2
	;;
esac
