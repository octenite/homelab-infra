#!/bin/bash
# The private companion repositories are submodules: private/ (secrets and
# the identifying inventory) and iot/ (device firmware). A fresh clone checks
# out the commit the public repository records, on no branch, which may be
# older than the newest commits. Everything that reads or writes secrets,
# every flash and every recovery must use their main branch, in step with
# GitHub. This check says whether that is the case, for every path given
# (default: both).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
problems=0

check() { # <submodule path>
	local name=$1 P="$REPO/$1" before=$problems branch ahead behind recorded
	[ -e "$P/.git" ] || {
		echo "$name/ is not checked out: run 'just setup'" >&2
		problems=$((problems + 1))
		return
	}
	branch=$(git -C "$P" symbolic-ref --quiet --short HEAD || true)
	if [ "$branch" != main ]; then
		echo "$name/ is not on main (${branch:-detached head}): git -C $name switch main"
		problems=$((problems + 1))
	fi
	if [ -n "$(git -C "$P" status --porcelain)" ]; then
		echo "$name/ has uncommitted changes:"
		git -C "$P" status --short
		problems=$((problems + 1))
	fi
	if git -C "$P" fetch --quiet origin main 2>/dev/null; then
		ahead=$(git -C "$P" rev-list --count origin/main..HEAD)
		behind=$(git -C "$P" rev-list --count HEAD..origin/main)
		if [ "$ahead" -gt 0 ]; then
			echo "$name/ has $ahead commit(s) that are not on GitHub: git -C $name push"
			problems=$((problems + 1))
		fi
		if [ "$behind" -gt 0 ]; then
			echo "$name/ is $behind commit(s) behind GitHub: git -C $name pull --ff-only"
			problems=$((problems + 1))
		fi
	else
		echo "$name/: GitHub not reachable, could not compare"
		problems=$((problems + 1))
	fi
	recorded=$(git -C "$REPO" ls-tree HEAD "$name" | awk '{print $3}')
	if [ -z "$recorded" ]; then
		echo "note: the public repository's HEAD does not record $name yet; the pull request that adds it does"
	elif [ "$recorded" != "$(git -C "$P" rev-parse HEAD)" ]; then
		echo "note: the public repository records an older $name commit ($(printf '%.7s' "$recorded")); the next public pull request moves it"
	fi
	if [ "$problems" -eq "$before" ]; then
		echo "$name/ is on main, clean and in step with GitHub ($(git -C "$P" log --oneline -n 1))"
	fi
}

if [ $# -eq 0 ]; then set -- private iot; fi
for p in "$@"; do check "$p"; done
[ "$problems" -eq 0 ]
