#!/bin/sh
# Policy test for the public repository.
#
# The public tree holds code and manifests only. Ciphertext and anything that
# identifies a person or a device live in the private companion repository
# (docs/ARCHITECTURE.md, section 9). This script fails when a tracked or
# untracked-but-not-ignored file breaks that rule.
#
# It is a net for accidents, not a proof: an identifier written in a form no
# pattern below knows still gets through. Review remains the control.

set -u

fail=0

# NUL-separated, so a name with a space or a newline is still one name. The
# private submodule and this file (which has to spell the patterns) are skipped.
list() {
	git ls-files -z --cached --others --exclude-standard -- . ':(exclude)private' ':(exclude)policy/public-tree.sh'
}

# A check that could not look must not pass.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
	echo "policy: not inside a work tree; nothing was checked"
	exit 2
}
[ "$(list | tr -cd '\0' | wc -c)" -gt 0 ] || {
	echo "policy: no files listed; nothing was checked"
	exit 2
}

# scan <ERE>: every match in every text file, as file:line:match. An
# expression grep rejects becomes a hit, so the run fails instead of finding
# nothing. Files that are listed but gone from the working tree, and
# directories, are skipped quietly (-s, -d skip).
scan() {
	printf '' | grep -E -e "$1" >/dev/null 2>&1
	if [ $? -gt 1 ]; then
		echo "policy-error: grep rejects the expression: $1"
		return 0
	fi
	list | xargs -0 -r grep -s -d skip -I -n -H -o -E -e "$1" || true
}

report() { # <what> <hits>
	[ -n "$2" ] || return 0
	echo "policy: $1:"
	printf '%s\n' "$2" | cut -c1-140 | sed 's/^/  /'
	fail=1
}

# 1. No secret-bearing file names.
report "secret-bearing file names are not allowed in the public tree" \
	"$(list | tr '\0' '\n' | grep -E '(\.sops\.|\.age$|\.agekey$|\.pem$|\.key$|(^|/)kubeconfig$|(^|/)talosconfig$|(^|/)keys\.txt$|\.tfstate|\.tfplan$)' || true)"

# 2. No ciphertext and no key material by content, whatever the file is called.
report "encrypted or key material in the public tree" \
	"$(scan 'ENC\[AES256_GCM,data:|BEGIN AGE ENCRYPTED FILE|AGE-SECRET-KEY-1[0-9A-Z]{10}|BEGIN ((OPENSSH|RSA|EC|DSA|PGP|ENCRYPTED) )?PRIVATE KEY|"encrypted_data"[[:space:]]*:')"

# 3. No hardware addresses, in any of the usual spellings:
#    aa:bb:cc:dd:ee:ff  aa-bb-cc-dd-ee-ff  aabb.ccdd.eeff  aabbccddeeff
# Allowed, because they identify no hardware:
#    00155d980003, 00155d990003   addresses this repository assigns to the backup VM's virtual adapters
#    0439297be951                 a commit abbreviation inside a module version in the research notes
allowed_hex='00155d980003|00155d990003|0439297be951'
report "hardware address in the public tree" \
	"$(scan '(^|[^0-9A-Fa-f:-])([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f:-]|$)|(^|[^0-9A-Fa-f.])([0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}([^0-9A-Fa-f.]|$)')"
# The unseparated form also matches twelve-digit numbers and words; only a
# token with both a digit and a letter counts.
report "hardware address (unseparated) in the public tree" \
	"$(scan '(^|[^0-9A-Za-z_/+=-])[0-9A-Fa-f]{12}([^0-9A-Za-z_/+=-]|$)' |
		grep -E '[0-9][0-9A-Fa-f]*[^0-9A-Fa-f]?$' |
		grep -E '[A-Fa-f][0-9A-Fa-f]*[^0-9A-Fa-f]?$' |
		grep -v -i -E "($allowed_hex)[^0-9A-Fa-f]?\$" || true)"

# 4. No e-mail addresses. The GitHub no-reply domain is the only exception.
report "e-mail address in the public tree" \
	"$(scan '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' | grep -v -E '@users\.noreply\.github\.com$' || true)"

if [ "$fail" -eq 0 ]; then
	echo "policy: public tree is clean"
fi
exit "$fail"
