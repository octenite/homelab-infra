#!/bin/bash
# Build the unattended Proxmox Backup Server install image for the VM on the
# workstation. The image is prepared on the hypervisor (which has the
# assistant and the bandwidth), verified, then copied to the workstation's
# F: drive, where scripts/node2/pbs-vm.ps1 -Iso attaches it.
#
#   build-install-iso.sh            build and copy
#
# Runs from the operator workstation (WSL) with a session open. The rendered
# answer file holds a password hash: it exists only in memory here and in the
# hypervisor's RAM-backed /run while the image is built. The image embeds it
# too: every copy on the hypervisor is removed when this script ends, however
# it ends, and pbs-vm.ps1 -Eject deletes the workstation's copy after the
# install.
set -euo pipefail

HOST=${PVE_HOST:-10.0.10.10}
ISO_NAME=${PBS_ISO:-proxmox-backup-server_4.2-1.iso}
ISO_SHA256=${PBS_ISO_SHA256:-2fb299deac3929253712c9c3dfc9237edbe70af83c8848467616b771a1d5453e}
ISO_URL="https://enterprise.proxmox.com/iso/${ISO_NAME}"
DEST_DIR=${PBS_ISO_DIR:-/mnt/f/homelab/iso}
DEST="${DEST_DIR}/pbs1-auto.iso"
REPO=$(cd "$(dirname "$0")/../.." && pwd)
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/dev/shm/homelab-session/age.key}"
WORK=/dev/shm/pbs-answer

# Callers pass commands that are meant to be assembled here and run there.
# shellcheck disable=SC2029
on_host() { ssh -o BatchMode=yes -o ConnectTimeout=10 "ops@${HOST}" "$@"; }

cleanup() {
	rm -rf "$WORK"
	on_host 'sudo rm -rf /run/pbs-install /root/pbs1-auto.iso' 2>/dev/null || true
}
trap cleanup EXIT

render() {
	[ -r "$SOPS_AGE_KEY_FILE" ] || {
		echo "No key session open. Run 'just session-start' first." >&2
		exit 1
	}
	rm -rf "$WORK" && mkdir -p "$WORK" && chmod 700 "$WORK"
	export ROOT_PASSWORD_HASH MAILTO SSH_KEYS
	ROOT_PASSWORD_HASH=$(sops decrypt --extract '["pbs_root_password"]' "$REPO/private/proxmox/pbs1.sops.yaml" | openssl passwd -6 -stdin)
	MAILTO=$(sed -n "s/^pve_mailto: \"\(.*\)\"[[:space:]]*\$/\1/p" "$REPO/private/proxmox/pve1.yaml" | tr -d '\r')
	SSH_KEYS=$(sed -n 's/^  - "\(.*\)"$/  "\1",/p' "$REPO/private/ansible/inventory/group_vars/all/ssh.yaml")
	# An empty value renders into an answer file the installer accepts and
	# then stops on, at the VM console.
	: "${ROOT_PASSWORD_HASH:?pbs_root_password is missing in private/proxmox/pbs1.sops.yaml}"
	: "${MAILTO:?pve_mailto is missing in private/proxmox/pve1.yaml (expected: pve_mailto: \"...\")}"
	: "${SSH_KEYS:?no keys found in private/ansible/inventory/group_vars/all/ssh.yaml}"
	python3 - "$REPO/infrastructure/pbs/answer.toml.tmpl" "$WORK/answer.toml" <<'PY'
import os, string, sys
src, dst = sys.argv[1], sys.argv[2]
text = string.Template(open(src).read()).substitute(os.environ)
with open(dst, "w", newline="\n") as f:
    f.write(text)
PY
	chmod 600 "$WORK/answer.toml"
	echo "answer file rendered in memory ($(wc -l <"$WORK/answer.toml") lines)"
}

render
mkdir -p "$DEST_DIR"
echo "--- hypervisor: answer file"
on_host 'sudo install -d -m 700 -o ops /run/pbs-install && cat > /run/pbs-install/answer.toml && chmod 600 /run/pbs-install/answer.toml' <"$WORK/answer.toml"
rm -rf "$WORK"
on_host sudo bash -s -- "$ISO_NAME" "$ISO_SHA256" "$ISO_URL" <<'EOF'
set -euo pipefail
iso_name=$1 iso_sha=$2 iso_url=$3
if ! command -v proxmox-auto-install-assistant >/dev/null || ! command -v xorriso >/dev/null || ! command -v wget >/dev/null; then
	DEBIAN_FRONTEND=noninteractive apt-get -qq install -y proxmox-auto-install-assistant xorriso wget >/dev/null
fi
proxmox-auto-install-assistant validate-answer /run/pbs-install/answer.toml
echo "--- hypervisor: image"
cd /root
if [ ! -f "$iso_name" ] || ! echo "$iso_sha  $iso_name" | sha256sum -c --status; then
	rm -f "$iso_name"
	wget -q "$iso_url"
fi
echo "$iso_sha  $iso_name" | sha256sum -c
echo "--- hypervisor: embed the answer file"
rm -f /root/pbs1-auto.iso
proxmox-auto-install-assistant prepare-iso "/root/$iso_name" --fetch-from iso --answer-file /run/pbs-install/answer.toml --output /root/pbs1-auto.iso
rm -rf /run/pbs-install
EOF
echo "--- workstation: copy to ${DEST}"
on_host 'sudo cat /root/pbs1-auto.iso' >"$DEST"
want=$(on_host 'sudo sha256sum /root/pbs1-auto.iso' | cut -d' ' -f1)
have=$(sha256sum "$DEST" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$have" ] || {
	rm -f "$DEST"
	echo "copy verification failed; the image was removed" >&2
	exit 1
}
echo "image ready and verified: ${DEST}"
echo "It embeds the root password hash; pbs-vm.ps1 -Eject deletes it after the install."
printf '%s\n' 'next, elevated PowerShell in the repository: powershell -ExecutionPolicy Bypass -File scripts\node2\pbs-vm.ps1 -Iso F:\homelab\iso\pbs1-auto.iso'
