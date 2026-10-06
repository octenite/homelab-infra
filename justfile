# Task runner. `just` with no arguments lists the recipes.
# Every recipe that CI runs is also runnable locally, with the same pinned tools.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# First-time setup of a working copy: tools, hooks, submodule.
setup:
    mise install
    pre-commit install
    git submodule update --init

# All fast checks. The pre-commit hook and the CI lint job run this.
lint: yaml shell actions policy ansible-lint tofu-lint

# OpenTofu: formatting and validation of every root, without a backend.
tofu-lint:
    #!/usr/bin/env bash
    set -euo pipefail
    tofu fmt -check -recursive infrastructure/opentofu
    for root in infrastructure/opentofu/roots/*/; do
        ( cd "$root" && tofu init -backend=false -input=false >/dev/null && tofu validate )
    done

# Run OpenTofu for one root with credentials from the private repository. Example: just tofu pve plan
tofu root *args:
    bash scripts/tofu/run.sh {{root}} {{args}}

# Install the pinned Ansible collections into infrastructure/ansible/collections.
ansible-deps:
    cd infrastructure/ansible && ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-galaxy collection install -r requirements.yml -p ./collections

# Ansible playbooks and roles, production profile.
ansible-lint: ansible-deps
    cd infrastructure/ansible && ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-lint --profile production --offline playbooks roles

# Open an operator session: SSH agent and decrypted age key, both in memory only.
session-start:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    sock="$HOME/.ssh/homelab-agent.sock"
    if ! SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1; then
        rm -f "$sock"
        ssh-agent -a "$sock" >/dev/null
        SSH_AUTH_SOCK="$sock" ssh-add "$HOME/.ssh/homelab_ed25519"
    fi
    mkdir -p /dev/shm/homelab-session
    age -d -o /dev/shm/homelab-session/age.key "$HOME/.config/sops/age/operator.age"
    echo "Session open. The decrypted key is in RAM only. Close it with: just session-end"

# Show one value from an encrypted file, using the open session. Example: just reveal private/proxmox/pve1.sops.yaml pve_root_password
reveal file key="":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    if [ -n "{{key}}" ]; then sops decrypt --extract '["{{key}}"]' "{{file}}"; echo; else sops decrypt "{{file}}"; fi

# Store one secret value in an encrypted file, typed at a hidden prompt (never on a command line). Creates the file if needed. Example: just secret-set private/ansible/inventory/host_vars/pve1/secrets.sops.yaml pve_backup_ping_url
secret-set file key:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    case "{{file}}" in private/*.sops.yaml) ;; *) echo "the file must be private/....sops.yaml"; exit 1 ;; esac
    read -rsp "value for {{key}}: " value; echo
    [ -n "$value" ] || { echo "empty value, nothing stored"; exit 1; }
    rel="${{file}}"; rel="${rel#private/}"
    if [ -f "{{file}}" ]; then
        [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
        SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key sops set "{{file}}" "[\"{{key}}\"]" "$(printf '%s' "$value" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    else
        mkdir -p "$(dirname "{{file}}")" /dev/shm/homelab-render
        printf '%s: %s\n' "{{key}}" "$(printf '%s' "$value" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" > /dev/shm/homelab-render/new.yaml
        ( cd private && sops encrypt --filename-override "$rel" /dev/shm/homelab-render/new.yaml > "$rel" )
        rm -f /dev/shm/homelab-render/new.yaml
    fi
    unset value
    echo "stored {{key}} in {{file}}; commit the private repository"

# Close the operator session and remove every decrypted artefact from memory.
session-end:
    rm -rf /dev/shm/homelab-session /dev/shm/homelab-render
    @echo "Session closed. The SSH agent keeps running until: ssh-agent -k, or the terminal closes."

# Read-only: compare network devices with Git. Example: just openwrt-check openwrt_routers
openwrt-check target="openwrt_routers":
    #!/usr/bin/env bash
    set -euo pipefail
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    if [ -r /dev/shm/homelab-session/age.key ]; then
        export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    else
        export ANSIBLE_VARS_ENABLED=host_group_vars
        echo "No key session open: secret values are compared masked. Run 'just session-start' for an exact comparison."
    fi
    ansible-playbook playbooks/openwrt-check.yaml -e "target={{target}}"

# Apply Git to a network device. Guarded: the device reverts by itself unless the change verifies.
openwrt-apply target:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    ansible-playbook playbooks/openwrt-apply.yaml -e "target={{target}}"

# Verify a device against Git and disarm a pending revert (after an apply left unverified on purpose).
openwrt-confirm target:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    ansible-playbook playbooks/openwrt-confirm.yaml -e "target={{target}}"

# Install the authorised SSH keys from the inventory on network devices.
openwrt-ssh-keys target="openwrt":
    #!/usr/bin/env bash
    set -euo pipefail
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    ansible-playbook playbooks/openwrt-ssh-keys.yaml -e "target={{target}}"

# Configure the hypervisor from Git (idempotent). Example: just pve-apply
pve-apply:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    ansible-playbook playbooks/pve.yaml

# Issue the hypervisor API tokens missing on the host; their secrets go straight into the private repository (attended).
pve-tokens:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    ansible-playbook playbooks/pve-tokens.yaml

# Connect the hypervisor to the backup server once: token, storage entry, encryption key; secrets go to the private repository (attended).
pve-backup-init:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    ansible-playbook playbooks/pve-backup-init.yaml

# Configure the backup server VM from Git (idempotent).
pbs-apply:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -r /dev/shm/homelab-session/age.key ] || { echo "No key session open. Run 'just session-start' first."; exit 1; }
    cd infrastructure/ansible
    export ANSIBLE_CONFIG="$PWD/ansible.cfg"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
    export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
    ansible-playbook playbooks/pbs.yaml

# Open the router's LuCI through an SSH tunnel: https://localhost:8443 (Ctrl+C closes it).
luci host="192.168.1.53":
    SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}" ssh -N -L 8443:127.0.0.1:443 root@{{host}}

# YAML syntax and style.
yaml:
    yamllint --strict .

# Shell scripts: static analysis and formatting. Untracked scripts count too.
shell:
    files="$(git ls-files -co --exclude-standard '*.sh')"; if [ -n "$files" ]; then shellcheck $files; shfmt -d $files; fi

# GitHub Actions workflow syntax.
actions:
    actionlint

# Rules for the public tree: no ciphertext, no identifiers.
policy:
    sh policy/public-tree.sh

# Secret scan of the full Git history and of the working tree.
secrets:
    gitleaks git --redact --no-banner .
    gitleaks dir --redact --no-banner .

# Heavier scanners. Needs MISE_ENV=ci so the tools are installed.
scan:
    trivy fs --scanners misconfig,secret,vuln --severity HIGH,CRITICAL --exit-code 1 --skip-dirs private .
    checkov --directory . --quiet --compact --skip-path private
    semgrep scan --config p/default --config p/secrets --config p/github-actions --metrics off --error --quiet --exclude private .

# Everything CI runs.
ci: lint secrets scan

# Format shell scripts in place.
fmt:
    files="$(git ls-files -co --exclude-standard '*.sh')"; if [ -n "$files" ]; then shfmt -w $files; fi
