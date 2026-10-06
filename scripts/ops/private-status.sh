#!/bin/bash
# The private repository is a submodule: a fresh clone checks out the commit
# the public repository records, on no branch, which may be older than the
# newest secrets. Everything that reads or writes secrets, and every
# recovery, must use its main branch, in step with GitHub. This check says
# whether that is the case.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
P="$REPO/private"
[ -e "$P/.git" ] || {
	echo "private/ is not checked out: run 'just setup'" >&2
	exit 1
}
problems=0
branch=$(git -C "$P" symbolic-ref --quiet --short HEAD || true)
if [ "$branch" != main ]; then
	echo "private/ is not on main (${branch:-detached head}): git -C private switch main"
	problems=1
fi
if [ -n "$(git -C "$P" status --porcelain)" ]; then
	echo "private/ has uncommitted changes:"
	git -C "$P" status --short
	problems=1
fi
if git -C "$P" fetch --quiet origin main 2>/dev/null; then
	ahead=$(git -C "$P" rev-list --count origin/main..HEAD)
	behind=$(git -C "$P" rev-list --count HEAD..origin/main)
	if [ "$ahead" -gt 0 ]; then
		echo "private/ has $ahead commit(s) that are not on GitHub: git -C private push"
		problems=1
	fi
	if [ "$behind" -gt 0 ]; then
		echo "private/ is $behind commit(s) behind GitHub: git -C private pull --ff-only"
		problems=1
	fi
else
	echo "private/: GitHub not reachable, could not compare"
	problems=1
fi
recorded=$(git -C "$REPO" ls-tree HEAD private | awk '{print $3}')
if [ "$recorded" != "$(git -C "$P" rev-parse HEAD)" ]; then
	echo "note: the public repository records an older private commit ($(printf '%.7s' "$recorded")); the next public pull request moves it"
fi
if [ "$problems" -eq 0 ]; then
	echo "private/ is on main, clean and in step with GitHub ($(git -C "$P" log --oneline -n 1))"
fi
exit "$problems"
