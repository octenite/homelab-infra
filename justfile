# Task runner. `just` with no arguments lists the recipes.
# Every recipe that CI runs is also runnable locally, with the same pinned tools.
# Recipes are thin: anything longer than a line or two lives in scripts/, where
# shellcheck and shfmt see it.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# First-time setup of a working copy: tools, hooks, and the private repository on its main branch.
setup:
    mise install
    pre-commit install
    git submodule update --init
    git -C private switch main
    git -C private pull --ff-only

# The private repository must be on main and in step with GitHub before secrets are written or a recovery starts.
private-status:
    bash scripts/ops/private-status.sh

# All fast checks. The pre-commit hook and the CI lint job run this.
lint: yaml shell actions policy templates ansible-lint tofu-lint

# OpenTofu: formatting and validation of every root, without a backend.
tofu-lint:
    bash scripts/tofu/lint.sh

# Run OpenTofu for one root with credentials from the private repository. Example: just tofu pve plan
[positional-arguments]
tofu root *args:
    bash scripts/tofu/run.sh "$@"

# Install the pinned Ansible collections into infrastructure/ansible/collections.
ansible-deps:
    cd infrastructure/ansible && ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-galaxy collection install -r requirements.yml -p ./collections

# Ansible playbooks and roles, production profile.
ansible-lint: ansible-deps
    cd infrastructure/ansible && ANSIBLE_CONFIG="$PWD/ansible.cfg" ansible-lint --profile production --offline playbooks roles

# Open an operator session: SSH agent and decrypted age key, both in memory only, both gone after 12 hours.
session-start:
    bash scripts/ops/session.sh start

# Close the operator session: age key removed, SSH key unloaded, agent stopped.
session-end:
    bash scripts/ops/session.sh end

# Is a session open?
session-status:
    bash scripts/ops/session.sh status

# Show one value from an encrypted file. Examples: just reveal private/proxmox/pve1.sops.yaml pve_root_password ; just reveal private/proxmox/backup-keys.sops.yaml pbs-node2 key
[positional-arguments]
reveal file key="" subkey="":
    bash scripts/ops/secret.sh reveal "$@"

# Store one secret value in an encrypted file, typed at a hidden prompt. Creates the file if needed. Example: just secret-set private/ansible/inventory/host_vars/pve1/secrets.sops.yaml pve_backup_ping_url
[positional-arguments]
secret-set file key:
    bash scripts/ops/secret.sh set "$@"

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
    bash scripts/ops/play.sh openwrt-apply -e "target={{target}}"

# Verify a device against Git and disarm a pending revert (after an apply left unverified on purpose).
openwrt-confirm target:
    bash scripts/ops/play.sh openwrt-confirm -e "target={{target}}"

# Install the authorised SSH keys from the inventory on network devices.
openwrt-ssh-keys target="openwrt":
    bash scripts/ops/play.sh openwrt-ssh-keys -e "target={{target}}"

# First contact with a freshly installed hypervisor (as root, once): operator account, keys, root login closed.
pve-bootstrap:
    bash scripts/ops/play.sh pve-bootstrap

# Configure the hypervisor from Git (idempotent).
pve-apply:
    bash scripts/ops/play.sh pve

# Issue the hypervisor API tokens missing on the host; their secrets go straight into the private repository (attended).
pve-tokens:
    bash scripts/ops/play.sh pve-tokens

# Connect the hypervisor to the backup server, or repair that connection after a rebuild of either side (attended).
pve-backup-init:
    bash scripts/ops/play.sh pve-backup-init

# Build unattended install media for the hypervisor. Examples: just pve-media validate ; just pve-media iso ; just pve-media prepare
[positional-arguments]
pve-media *args:
    bash scripts/pve/build-install-media.sh "$@"

# First contact with a freshly installed backup server (as root, once). Needs the management window (pbs-vm.ps1 -Manage).
pbs-bootstrap:
    bash scripts/ops/play.sh pbs-bootstrap

# Configure the backup server VM from Git (idempotent). Needs the management window (pbs-vm.ps1 -Manage).
pbs-apply:
    bash scripts/ops/play.sh pbs

# Build the unattended install image for the backup server VM and copy it to the workstation.
pbs-media:
    bash scripts/pbs/build-install-iso.sh

# Deny test of the backup path's fences from every vantage point (read-only probes). Fails when one probe disagrees.
test-fences:
    bash scripts/tests/backup-fences.sh

# Open the router's LuCI through an SSH tunnel: https://localhost:8443 (Ctrl+C closes it).
luci host="192.168.1.53":
    SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}" ssh -N -L 8443:127.0.0.1:443 root@{{host}}

# YAML syntax and style.
yaml:
    yamllint --strict .

# Shell scripts: static analysis and formatting. Untracked scripts count too.
shell:
    files="$(git ls-files -co --exclude-standard '*.sh')"; if [ -n "$files" ]; then shellcheck $files; shfmt -d $files; fi

# Answer-file templates: rendered with dummy values and parsed as TOML.
templates:
    python3 scripts/tests/render-templates.py

# PowerShell scripts: parse and static analysis. Needs pwsh; CI has it, a workstation without it skips with a notice.
powershell:
    bash scripts/tests/powershell-lint.sh

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
ci: lint powershell secrets scan

# Format shell scripts in place.
fmt:
    files="$(git ls-files -co --exclude-standard '*.sh')"; if [ -n "$files" ]; then shfmt -w $files; fi
