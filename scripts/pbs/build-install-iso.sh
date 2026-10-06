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
# hypervisor's RAM-backed /run while the image is built.
set -euo pipefail

HOST=${PVE_HOST:-10.0.10.10}
ISO_NAME=${PBS_ISO:-proxmox-backup-server_4.2-1.iso}
ISO_SHA256=${PBS_ISO_SHA256:-2fb299deac3929253712c9c3dfc9237edbe70af83c8848467616b771a1d5453e}
ISO_URL="https://enterprise.proxmox.com/iso/${ISO_NAME}"
DEST_DIR=${PBS_ISO_DIR:-/mnt/f/homelab/iso}
DEST="${DEST_DIR}/pbs1-auto.iso"
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 ops@${HOST}"

render() {
	local work=/dev/shm/pbs-answer
	rm -rf "$work" && mkdir -p "$work" && chmod 700 "$work"
	export ROOT_PASSWORD_HASH MAILTO SSH_KEYS
	ROOT_PASSWORD_HASH=$(sops decrypt --extract '["pbs_root_password"]' "$REPO/private/proxmox/pbs1.sops.yaml" | openssl passwd -6 -stdin)
	MAILTO=$(sed -n "s/^pve_mailto: \"\(.*\)\"$/\1/p" "$REPO/private/proxmox/pve1.yaml")
	SSH_KEYS=$(sed -n 's/^  - "\(.*\)"$/  "\1",/p' "$REPO/private/ansible/inventory/group_vars/all/ssh.yaml")
	[ -n "$ROOT_PASSWORD_HASH" ] && [ -n "$MAILTO" ] && [ -n "$SSH_KEYS" ]
	python3 - "$REPO/infrastructure/pbs/answer.toml.tmpl" "$work/answer.toml" <<'PY'
import os, string, sys
src, dst = sys.argv[1], sys.argv[2]
text = string.Template(open(src).read()).substitute(os.environ)
with open(dst, "w", newline="\n") as f:
    f.write(text)
PY
	chmod 600 "$work/answer.toml"
	echo "answer file rendered in memory ($(wc -l <"$work/answer.toml") lines)"
}

render
mkdir -p "$DEST_DIR"
echo "--- hypervisor: answer file"
$SSH "sudo install -d -m 700 -o ops /run/pbs-install"
scp -q /dev/shm/pbs-answer/answer.toml "ops@${HOST}:/run/pbs-install/answer.toml"
rm -rf /dev/shm/pbs-answer
$SSH sudo bash -s <<EOF
set -euo pipefail
command -v proxmox-auto-install-assistant >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get -qq install -y proxmox-auto-install-assistant xorriso >/dev/null; }
proxmox-auto-install-assistant validate-answer /run/pbs-install/answer.toml
echo "--- hypervisor: ISO"
cd /root
if [ ! -f "${ISO_NAME}" ] || ! echo "${ISO_SHA256}  ${ISO_NAME}" | sha256sum -c --status; then
  rm -f "${ISO_NAME}"
  wget -q "${ISO_URL}"
fi
echo "${ISO_SHA256}  ${ISO_NAME}" | sha256sum -c
echo "--- hypervisor: embed the answer file"
rm -f /root/pbs1-auto.iso
proxmox-auto-install-assistant prepare-iso "/root/${ISO_NAME}" --fetch-from iso --answer-file /run/pbs-install/answer.toml --output /root/pbs1-auto.iso
rm -rf /run/pbs-install
chown ops /root/pbs1-auto.iso
mv /root/pbs1-auto.iso /home/ops/pbs1-auto.iso
sha256sum /home/ops/pbs1-auto.iso | cut -d' ' -f1 > /home/ops/pbs1-auto.iso.sha256
EOF
echo "--- workstation: copy to ${DEST}"
scp -q "ops@${HOST}:/home/ops/pbs1-auto.iso" "$DEST"
want=$($SSH cat /home/ops/pbs1-auto.iso.sha256)
have=$(sha256sum "$DEST" | cut -d' ' -f1)
[ "$want" = "$have" ] || {
	echo "copy verification failed" >&2
	exit 1
}
$SSH rm -f /home/ops/pbs1-auto.iso /home/ops/pbs1-auto.iso.sha256
echo "image ready and verified: ${DEST}"
printf '%s\n' 'next, elevated PowerShell: scripts\node2\pbs-vm.ps1 -Iso F:\homelab\iso\pbs1-auto.iso'
