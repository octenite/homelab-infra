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
lint: yaml shell actions policy

# YAML syntax and style.
yaml:
    yamllint --strict .

# Shell scripts: static analysis and formatting.
shell:
    files="$(git ls-files '*.sh')"; if [ -n "$files" ]; then shellcheck $files; shfmt -d $files; fi

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
    files="$(git ls-files '*.sh')"; if [ -n "$files" ]; then shfmt -w $files; fi
