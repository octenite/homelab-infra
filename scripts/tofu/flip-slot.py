#!/usr/bin/env python3
"""Swap the two key slots in the encryption block of an OpenTofu root.

A root's versions.tf holds two key providers, "state" and "state_alt". One
writes the state with the current passphrase; the other is the fallback for
reading, with the previous passphrase. OpenTofu stores the salt of a key
under the provider's name and wants the writing method named statically, so a
passphrase rotation has to change which slot writes. This script makes that
change, the same way every time. It is called by scripts/tofu/passphrase.sh.

    flip-slot.py <versions.tf>            swap the slots
    flip-slot.py --show <versions.tf>     print the slot that writes
"""

import pathlib
import re
import sys

BLOCK = re.compile(r"(?s)^  encryption \{\n.*?^  \}\n", re.M)
METHOD = re.compile(r"^(\s+method = method\.aes_gcm\.)(state_alt|state)$", re.M)
WRITER = re.compile(r"(?s)^    state \{\n\s+method = method\.aes_gcm\.(state_alt|state)$", re.M)


def writer(block: str) -> str:
    found = WRITER.search(block)
    if not found:
        sys.exit("the state block of the encryption settings was not found")
    return found.group(1)


def flip(block: str) -> str:
    marker = "\0"
    block = block.replace("var.state_passphrase_previous", marker)
    block = block.replace("var.state_passphrase", "var.state_passphrase_previous")
    block = block.replace(marker, "var.state_passphrase")
    return METHOD.sub(lambda m: m.group(1) + ("state" if m.group(2) == "state_alt" else "state_alt"), block)


def main() -> int:
    args = sys.argv[1:]
    show = args[:1] == ["--show"]
    if show:
        args = args[1:]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    path = pathlib.Path(args[0])
    text = path.read_text(encoding="utf-8")
    found = BLOCK.search(text)
    if not found:
        sys.exit(f"{path}: no encryption block")
    block = found.group(0)
    for needed in ('key_provider "pbkdf2" "state"', 'key_provider "pbkdf2" "state_alt"', "var.state_passphrase_previous"):
        if needed not in block:
            sys.exit(f"{path}: the encryption block does not have the two-slot form ({needed} is missing)")
    if show:
        print(writer(block))
        return 0
    before = writer(block)
    new_block = flip(block)
    after = writer(new_block)
    if after == before or flip(new_block) != block:
        sys.exit(f"{path}: the swap did not produce a clean, reversible result; nothing was written")
    path.write_text(text[: found.start()] + new_block + text[found.end() :], encoding="utf-8", newline="\n")
    print(f"{path}: the slot that writes is now {after} (was {before})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
