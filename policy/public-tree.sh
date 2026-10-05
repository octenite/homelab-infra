#!/bin/sh
# Policy test for the public repository.
#
# The public tree holds code and manifests only. Ciphertext and anything that
# identifies a person or a device live in the private companion repository
# (docs/ARCHITECTURE.md, section 9). This script fails when a tracked or
# staged file breaks that rule.

set -u

fail=0
files=$(git ls-files --cached --others --exclude-standard | grep -v '^private/' || true)

# 1. No SOPS files and no key material by name.
bad=$(printf '%s\n' "$files" | grep -E '(\.sops\.|\.age$|\.pem$|\.key$|(^|/)kubeconfig$|(^|/)talosconfig$|\.tfstate|\.tfplan$)' || true)
if [ -n "$bad" ]; then
	echo "policy: secret-bearing file names are not allowed in the public tree:"
	printf '%s\n' "$bad" | sed 's/^/  /'
	fail=1
fi

# 2. No MAC addresses.
# 3. No e-mail addresses. The GitHub no-reply domain is the only exception.
for f in $files; do
	[ -f "$f" ] || continue
	case "$f" in
	policy/public-tree.sh) continue ;;
	esac
	if grep -I -n -E '(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:]|$)' "$f" >/dev/null 2>&1; then
		echo "policy: MAC address in $f:"
		grep -I -n -E '(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:]|$)' "$f" | cut -c1-120 | sed 's/^/  /'
		fail=1
	fi
	hits=$(grep -I -n -o -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' "$f" 2>/dev/null | grep -v -E '@users\.noreply\.github\.com$' || true)
	if [ -n "$hits" ]; then
		echo "policy: e-mail address in $f:"
		printf '%s\n' "$hits" | cut -c1-120 | sed 's/^/  /'
		fail=1
	fi
done

if [ "$fail" -eq 0 ]; then
	echo "policy: public tree is clean"
fi
exit "$fail"
