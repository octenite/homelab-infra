#!/bin/bash
# Build unattended Proxmox VE install media on an existing, reachable host
# and arm a one-time boot into it. The reboot itself is a separate command.
#
#   build-install-media.sh prepare   render the answer file, build the ISO on
#                                    the host, write it to the USB stick, arm
#                                    a one-time boot entry
#   build-install-media.sh reboot    reboot the host into the installer
#
# Runs from the operator workstation with a session open (just session-start).
# The rendered answer file holds a password hash: it exists only in memory on
# the workstation and in the host's RAM-backed /run while the ISO is built.
set -euo pipefail

HOST=${PVE_HOST:-10.0.10.10}
ISO_NAME=${PVE_ISO:-proxmox-ve_9.2-1.iso}
ISO_SHA256=${PVE_ISO_SHA256:-4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c}
ISO_URL="https://enterprise.proxmox.com/iso/${ISO_NAME}"
USB_SERIAL=${PVE_USB_SERIAL:-}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 root@${HOST}"

render() {
	local work=/dev/shm/pve-answer
	rm -rf "$work" && mkdir -p "$work" && chmod 700 "$work"
	# secrets and identifiers from the private inventory, decrypted into this
	# process only
	export ROOT_PASSWORD_HASH MAILTO DISK_SERIAL SSH_KEYS
	ROOT_PASSWORD_HASH=$(sops decrypt --extract '["pve_root_password"]' "$REPO/private/proxmox/pve1.sops.yaml" | openssl passwd -6 -stdin)
	MAILTO=$(sed -n "s/^pve_mailto: \"\(.*\)\"$/\1/p" "$REPO/private/proxmox/pve1.yaml")
	DISK_SERIAL=$(sed -n "s/^pve_disk_serial: \"\(.*\)\"$/\1/p" "$REPO/private/proxmox/pve1.yaml")
	SSH_KEYS=$(sed -n 's/^  - "\(.*\)"$/  "\1",/p' "$REPO/private/ansible/inventory/group_vars/all/ssh.yaml")
	[ -n "$ROOT_PASSWORD_HASH" ] && [ -n "$MAILTO" ] && [ -n "$DISK_SERIAL" ] && [ -n "$SSH_KEYS" ]
	python3 - "$REPO/infrastructure/proxmox/answer.toml.tmpl" "$work/answer.toml" <<'PY'
import os, string, sys
src, dst = sys.argv[1], sys.argv[2]
text = string.Template(open(src).read()).substitute(os.environ)
with open(dst, "w", newline="\n") as f:
    f.write(text)
PY
	chmod 600 "$work/answer.toml"
	echo "answer file rendered in memory ($(wc -l <"$work/answer.toml") lines)"
}

prepare() {
	[ -n "$USB_SERIAL" ] || {
		echo "set PVE_USB_SERIAL to the udev ID_SERIAL of the stick" >&2
		exit 2
	}
	render
	echo "--- host: tools"
	$SSH "mkdir -p /run/pve-install && chmod 700 /run/pve-install"
	scp -q /dev/shm/pve-answer/answer.toml "root@${HOST}:/run/pve-install/answer.toml"
	rm -rf /dev/shm/pve-answer
	$SSH bash -s <<EOF
set -euo pipefail
# the old host has only the enterprise repository, which needs a subscription
if ! command -v proxmox-auto-install-assistant >/dev/null; then
  cat >/etc/apt/sources.list.d/pve-no-subscription.sources <<'SRC'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
SRC
  rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
  apt-get -qq update
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y proxmox-auto-install-assistant xorriso >/dev/null
fi
proxmox-auto-install-assistant --version
echo "--- host: answer file"
proxmox-auto-install-assistant validate-answer /run/pve-install/answer.toml
echo "--- host: ISO"
cd /root
if [ ! -f "${ISO_NAME}" ] || ! echo "${ISO_SHA256}  ${ISO_NAME}" | sha256sum -c --status; then
  rm -f "${ISO_NAME}"
  wget -q --show-progress --progress=dot:giga "${ISO_URL}"
fi
echo "${ISO_SHA256}  ${ISO_NAME}" | sha256sum -c
echo "--- host: embed the answer file"
# The prepared image is larger than the RAM disk, so it is built on the root
# filesystem, which the installer is about to erase anyway.
rm -f /root/install.iso /root/*-auto-from-iso.iso
proxmox-auto-install-assistant prepare-iso "/root/${ISO_NAME}" --fetch-from iso --answer-file /run/pve-install/answer.toml --output /root/install.iso || { echo "prepare-iso failed"; exit 1; }
rm -f /run/pve-install/answer.toml
src=\$(stat -c %s "/root/${ISO_NAME}"); out=\$(stat -c %s /root/install.iso)
[ "\$out" -ge "\$src" ] || { echo "prepared image (\$out bytes) is smaller than the source (\$src bytes); aborting"; exit 1; }
ls -l /root/install.iso
echo "--- host: USB stick"
dev=\$(readlink -f "/dev/disk/by-id/usb-${USB_SERIAL}")
[ -b "\$dev" ] || { echo "stick with serial ${USB_SERIAL} not found"; exit 1; }
root=\$(findmnt -n -o SOURCE / | sed -E 's#/dev/mapper/##')
pvs --noheadings -o pv_name | grep -q "\$dev" && { echo "refusing: \$dev is a physical volume of the system"; exit 1; }
mount | grep -q "^\$dev" && { echo "refusing: \$dev is mounted"; exit 1; }
echo "writing to \$dev (\$(lsblk -dn -o SIZE,TRAN,MODEL \$dev))"
dd if=/root/install.iso of="\$dev" bs=4M conv=fsync status=none
sync
partprobe "\$dev" 2>/dev/null || true
sleep 2
lsblk -o NAME,SIZE,FSTYPE,LABEL "\$dev"
echo "--- host: read the image back from the stick and compare"
cmp -n "\$(stat -c %s /root/install.iso)" "\$dev" /root/install.iso && echo "stick content verified"
rm -f /root/install.iso
echo "--- host: one-time boot entry"
for n in \$(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\* pve-install.*/\1/p'); do efibootmgr -q -B -b "\$n"; done
efibootmgr -q -c -d "\$dev" -p 2 -L pve-install -l '\\EFI\\BOOT\\BOOTX64.EFI'
id=\$(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\* pve-install.*/\1/p' | head -n 1)
efibootmgr -q -n "\$id"
efibootmgr | grep -E "BootNext|BootOrder|pve-install"
EOF
	echo "media ready; next: $0 reboot"
}

do_reboot() {
	# the command runs on the host; its substitutions must not expand locally
	# shellcheck disable=SC2016
	$SSH 'efibootmgr | grep -q "^BootNext:" || { echo "no one-time boot entry armed"; exit 1; }; echo "rebooting into the installer at $(date +%T)"; (sleep 2; reboot) >/dev/null 2>&1 &'
}

case "${1:-}" in
prepare) prepare ;;
reboot) do_reboot ;;
*)
	echo "usage: $0 prepare|reboot" >&2
	exit 2
	;;
esac
