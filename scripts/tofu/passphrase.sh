#!/bin/bash
# Change the passphrase that encrypts the OpenTofu state, without ever having
# a state that cannot be read (docs/runbooks/rotate-state-passphrase.md).
#
#   passphrase.sh begin [--prompt]   the current passphrase becomes the previous one; a new one is
#                                    generated (or typed at a hidden prompt) and becomes current;
#                                    the two key slots in every root's versions.tf swap roles
#   passphrase.sh status             which roots' states read with the current passphrase alone
#   passphrase.sh finish             refuses unless every state does; then forgets the previous one
#   passphrase.sh back               swaps current and previous: the way out of a rotation that
#                                    is not wanted after all (apply every root again, then finish)
#
# Between begin and finish, `just tofu <root> apply` in every root writes its
# state with the new passphrase; reading falls back to the previous one.
# No passphrase is printed, passed as an argument or written to a disk in the
# clear. Runs from the workstation with a session open.
set -euo pipefail
umask 077

REPO=$(cd "$(dirname "$0")/../.." && pwd)
FILE="$REPO/private/opentofu/b2.sops.yaml"
CUR='["tofu_state_passphrase"]'
PREV='["tofu_state_passphrase_previous"]'
export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
[ -r "$SOPS_AGE_KEY_FILE" ] || {
	echo "No key session open. Run 'just session-start' first." >&2
	exit 1
}

has_previous() { sops decrypt --extract "$PREV" "$FILE" >/dev/null 2>&1; }
as_json() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
# store <path>: the value on standard input, without a trailing newline, into the encrypted file
store() { as_json | sops set --value-stdin "$FILE" "$1"; }

roots() {
	local d
	for d in "$REPO"/infrastructure/opentofu/roots/*/; do basename "$d"; done
}

# The slot that writes changes with every rotation, in every root alike.
flip_slots() {
	local r
	for r in $(roots); do python3 "$REPO/scripts/tofu/flip-slot.py" "$REPO/infrastructure/opentofu/roots/$r/versions.tf"; done
}

# reads_alone <root>: does the state of this root decrypt with the current passphrase and nothing else?
reads_alone() {
	[ -d "$REPO/infrastructure/opentofu/roots/$1/.terraform" ] || return 2
	TOFU_NO_FALLBACK=1 bash "$REPO/scripts/tofu/run.sh" "$1" state list >/dev/null 2>&1
}

status() {
	local r rc bad=0
	if has_previous; then echo "a rotation is under way: a previous passphrase is stored"; else echo "no rotation under way"; fi
	for r in $(roots); do
		rc=0
		reads_alone "$r" || rc=$?
		case "$rc" in
		0) echo "  $r: reads with the current passphrase alone" ;;
		2) echo "  $r: not initialised on this workstation (run: just tofu $r init); not checked" && bad=1 ;;
		*) echo "  $r: does NOT read with the current passphrase alone (run: just tofu $r apply)" && bad=1 ;;
		esac
	done
	return "$bad"
}

case "${1:-}" in
begin)
	if has_previous; then
		echo "a rotation is already under way; finish it or go back first" >&2
		exit 1
	fi
	status >/dev/null || {
		echo "not every state reads with the current passphrase; nothing was changed. See: $0 status" >&2
		exit 1
	}
	sops decrypt --extract "$CUR" "$FILE" | tr -d '\n' | store "$PREV"
	if [ "${2:-}" = --prompt ]; then
		read -rsp "new state passphrase (16 characters or more): " new
		echo
		[ "${#new}" -ge 16 ] || {
			sops unset "$FILE" "$PREV"
			echo "too short; nothing was changed" >&2
			exit 1
		}
		printf '%s' "$new" | store "$CUR"
		unset new
	else
		openssl rand -base64 33 | tr -d '\n' | store "$CUR"
	fi
	flip_slots
	echo "new passphrase stored; the old one is kept as the fallback. versions.tf of every root was changed: commit that with the rotation."
	echo "next: 'just tofu <root> apply' for each of: $(roots | tr '\n' ' ')"
	echo "then: copy the new passphrase to the password manager (just reveal private/opentofu/b2.sops.yaml tofu_state_passphrase), '$0 finish', and commit the private repository."
	;;
status)
	status
	;;
finish)
	has_previous || {
		echo "no rotation under way" >&2
		exit 1
	}
	status || {
		echo "the previous passphrase is still needed; nothing was changed" >&2
		exit 1
	}
	sops unset "$FILE" "$PREV"
	echo "previous passphrase forgotten. Commit the private repository; the state copies in it are the re-encrypted ones."
	;;
back)
	has_previous || {
		echo "no rotation under way; nothing to go back to" >&2
		exit 1
	}
	tmp=$(mktemp -d /dev/shm/tofu-passphrase.XXXXXX)
	trap 'rm -rf "$tmp"' EXIT
	sops decrypt --extract "$CUR" "$FILE" | tr -d '\n' >"$tmp/cur"
	sops decrypt --extract "$PREV" "$FILE" | tr -d '\n' >"$tmp/prev"
	store "$CUR" <"$tmp/prev"
	store "$PREV" <"$tmp/cur"
	flip_slots
	echo "swapped: the earlier passphrase is current again, the newer one is the fallback."
	echo "next: 'just tofu <root> apply' for each root, then '$0 finish'."
	;;
*)
	echo "usage: $0 begin [--prompt] | status | finish | back" >&2
	exit 2
	;;
esac
