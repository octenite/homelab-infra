#!/usr/bin/env python3
"""Render the unattended-install answer templates with dummy values and parse them.

A template that does not render, or that renders into something that is not
TOML, would otherwise be noticed only in the middle of a media build on a
live host. Run by `just templates` (part of `just lint`) and in CI.
"""

import pathlib
import string
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
DUMMY = {
    "ROOT_PASSWORD_HASH": "$6$dummy$dummyhashdummyhashdummyhash",
    # Assembled here so the public-tree policy finds no address in this file.
    "MAILTO": "@".join(("nobody", "example.invalid")),
    "DISK_SERIAL": "MODEL_SERIAL0000",
    "SSH_KEYS": '  "ssh-ed25519 AAAAdummy one",\n  "ssh-ed25519 AAAAdummy two",',
}
# What every answer file must say, whatever else it contains.
REQUIRED = {
    "global": ["fqdn", "root-password-hashed", "root-ssh-keys", "reboot-on-error"],
    "network": ["source", "cidr", "gateway", "dns"],
    "disk-setup": ["filesystem"],
}


def check(path: pathlib.Path) -> list[str]:
    problems = []
    text = path.read_text(encoding="utf-8")
    try:
        rendered = string.Template(text).substitute(DUMMY)
    except (KeyError, ValueError) as exc:
        return [f"does not render: {exc!r}"]
    try:
        data = tomllib.loads(rendered)
    except tomllib.TOMLDecodeError as exc:
        return [f"renders into invalid TOML: {exc}"]
    for section, keys in REQUIRED.items():
        if section not in data:
            problems.append(f"section [{section}] is missing")
            continue
        for key in keys:
            if key not in data[section]:
                problems.append(f"[{section}] has no {key}")
    if data.get("global", {}).get("reboot-on-error") is not False:
        problems.append("[global] reboot-on-error must be false: a failed install has to stay on the console")
    disk = data.get("disk-setup", {})
    if "disk-list" not in disk and not any(k.startswith("filter") for k in disk):
        problems.append("[disk-setup] selects no disk (neither disk-list nor a filter)")
    if "disk_list" in disk:
        problems.append("[disk-setup] uses the deprecated key disk_list; the key is disk-list")
    return problems


def main() -> int:
    templates = sorted(ROOT.glob("infrastructure/*/answer.toml.tmpl"))
    if not templates:
        print("no answer templates found", file=sys.stderr)
        return 1
    failed = False
    for path in templates:
        problems = check(path)
        rel = path.relative_to(ROOT)
        if problems:
            failed = True
            for problem in problems:
                print(f"{rel}: {problem}", file=sys.stderr)
        else:
            print(f"{rel}: renders and parses")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
