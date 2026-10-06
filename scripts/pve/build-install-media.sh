#!/bin/bash
# Unattended Proxmox VE install media for the hypervisor.
#
#   build-install-media.sh validate   render the answer file and let the installer's own tool check it
#   build-install-media.sh iso        build the image on a builder host and copy it to the workstation
#   build-install-media.sh prepare    build on the running hypervisor, write its USB stick, arm a one-time boot
#   build-install-media.sh reboot     reboot the hypervisor into the armed installer
#
# Two situations:
#   planned reinstall   the hypervisor runs: prepare, then reboot. Nobody touches the machine.
#   disaster recovery   the hypervisor is dead: `iso` builds the image on another Debian 13 host that has the
#                       Proxmox repository (the backup server VM qualifies; open its management window first)
#                       and puts it on the workstation, to be written to a stick there and booted by hand.
#                       docs/runbooks/restore-pve-host.md has the steps and the fallback without any tooling.
#
# Runs from the operator workstation with a session open (just session-start);
# `just pve-media <command>` sets nothing extra. The rendered answer file holds
# a password hash: it exists only in memory on the workstation and in the
# builder's RAM-backed /run while the image is built. The image itself embeds
# it; the hypervisor role wipes the stick after the install, and `iso` says
# where its copy is so it can be deleted after use.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
HOST=${PVE_HOST:-10.0.10.10}
ISO_NAME=${PVE_ISO:-proxmox-ve_9.2-1.iso}
ISO_SHA256=${PVE_ISO_SHA256:-4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c}
ISO_URL="https://enterprise.proxmox.com/iso/${ISO_NAME}"
PRIVATE="$REPO/private/proxmox/pve1.yaml"
DEST_DIR=${PVE_ISO_DIR:-/mnt/f/homelab/iso}
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$HOME/.ssh/homelab-agent.sock}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/dev/shm/homelab-session/age.key}"

# The builder: the hypervisor itself, or with PVE_BUILDER=pbs1 the backup
# server VM through the workstation's management forward.
case "${PVE_BUILDER:-pve1}" in
pve1) BUILDER=(-o BatchMode=yes -o ConnectTimeout=10 "ops@${HOST}") ;;
pbs1)
	gw=$(ip -4 route show default | awk '{print $3; exit}')
	BUILDER=(-o BatchMode=yes -o ConnectTimeout=10 -o HostKeyAlias=pbs1 -p 2222 "ops@${gw}")
	;;
*)
	echo "PVE_BUILDER must be pve1 or pbs1" >&2
	exit 2
	;;
esac
# Callers pass commands that are meant to be assembled here and run there.
# shellcheck disable=SC2029
on_builder() { ssh "${BUILDER[@]}" "$@"; }
to_builder() { # <local file> <remote path>, through the same connection settings
	on_builder "sudo install -d -m 700 -o ops /run/pve-install && cat > $2 && chmod 600 $2" <"$1"
}

# Everything that carries the password hash goes when a build ends, however
# it ends: the rendered answer file here and on the builder, the image on the
# builder, and a copy on the workstation that was not verified.
DEST_UNVERIFIED=""
cleanup() {
	rm -rf /dev/shm/pve-answer
	[ -z "$DEST_UNVERIFIED" ] || rm -f "$DEST_UNVERIFIED"
	on_builder 'sudo rm -rf /run/pve-install /root/install.iso' 2>/dev/null || true
}

private_value() { # <key> : the quoted value of "key: "value"" in the private identifiers file
	sed -n "s/^$1: \"\(.*\)\"[[:space:]]*\$/\1/p" "$PRIVATE" | tr -d '\r'
}

render() {
	[ -r "$SOPS_AGE_KEY_FILE" ] || {
		echo "No key session open. Run 'just session-start' first." >&2
		exit 1
	}
	local work=/dev/shm/pve-answer
	rm -rf "$work" && mkdir -p "$work" && chmod 700 "$work"
	# Secrets and identifiers from the private repository, into this process only.
	export ROOT_PASSWORD_HASH MAILTO DISK_SERIAL SSH_KEYS
	ROOT_PASSWORD_HASH=$(sops decrypt --extract '["pve_root_password"]' "$REPO/private/proxmox/pve1.sops.yaml" | openssl passwd -6 -stdin)
	MAILTO=$(private_value pve_mailto)
	DISK_SERIAL=$(private_value pve_disk_serial)
	SSH_KEYS=$(sed -n 's/^  - "\(.*\)"$/  "\1",/p' "$REPO/private/ansible/inventory/group_vars/all/ssh.yaml")
	# Every value must be present: an empty one renders into an answer file
	# that the installer accepts and then stops on, at the console, with the
	# host already down.
	: "${ROOT_PASSWORD_HASH:?pve_root_password is missing in private/proxmox/pve1.sops.yaml}"
	: "${MAILTO:?pve_mailto is missing in private/proxmox/pve1.yaml (expected: pve_mailto: \"...\")}"
	: "${DISK_SERIAL:?pve_disk_serial is missing in private/proxmox/pve1.yaml (expected: pve_disk_serial: \"...\")}"
	: "${SSH_KEYS:?no keys found in private/ansible/inventory/group_vars/all/ssh.yaml}"
	python3 - "$REPO/infrastructure/proxmox/answer.toml.tmpl" "$work/answer.toml" <<'PY'
import os, string, sys
src, dst = sys.argv[1], sys.argv[2]
text = string.Template(open(src).read()).substitute(os.environ)
with open(dst, "w", newline="\n") as f:
    f.write(text)
PY
	chmod 600 "$work/answer.toml"
	echo "answer file rendered in memory ($(wc -l <"$work/answer.toml") lines), disk filter and $(grep -c 'ssh-' "$work/answer.toml") key(s) set"
}

upload_answer() {
	to_builder /dev/shm/pve-answer/answer.toml /run/pve-install/answer.toml
	rm -rf /dev/shm/pve-answer
}

# Runs on the builder as root; leaves /root/install.iso there.
build_remote() {
	on_builder sudo bash -s -- "$ISO_NAME" "$ISO_SHA256" "$ISO_URL" <<'EOF'
set -euo pipefail
iso_name=$1 iso_sha=$2 iso_url=$3
if ! command -v proxmox-auto-install-assistant >/dev/null || ! command -v xorriso >/dev/null || ! command -v wget >/dev/null; then
	DEBIAN_FRONTEND=noninteractive apt-get -qq install -y proxmox-auto-install-assistant xorriso wget >/dev/null
fi
echo "--- builder: answer file"
proxmox-auto-install-assistant validate-answer /run/pve-install/answer.toml
echo "--- builder: image"
cd /root
if [ ! -f "$iso_name" ] || ! echo "$iso_sha  $iso_name" | sha256sum -c --status; then
	rm -f "$iso_name"
	wget -q "$iso_url"
fi
echo "$iso_sha  $iso_name" | sha256sum -c
echo "--- builder: embed the answer file"
rm -f /root/install.iso
proxmox-auto-install-assistant prepare-iso "/root/$iso_name" --fetch-from iso --answer-file /run/pve-install/answer.toml --output /root/install.iso
rm -rf /run/pve-install
src=$(stat -c %s "/root/$iso_name")
out=$(stat -c %s /root/install.iso)
[ "$out" -ge "$src" ] || { echo "prepared image ($out bytes) is smaller than the source ($src bytes); aborting"; exit 1; }
ls -l /root/install.iso
EOF
}

validate() {
	trap cleanup EXIT
	render
	upload_answer
	on_builder sudo bash -s <<'EOF'
set -euo pipefail
command -v proxmox-auto-install-assistant >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get -qq install -y proxmox-auto-install-assistant >/dev/null
proxmox-auto-install-assistant validate-answer /run/pve-install/answer.toml
rm -rf /run/pve-install
EOF
	echo "answer file valid; nothing was built or written"
}

iso() {
	local dest="$DEST_DIR/pve1-auto.iso" want have
	# Before anything is built: a missing drive should not be found last.
	mkdir -p "$DEST_DIR"
	trap cleanup EXIT
	render
	upload_answer
	build_remote
	DEST_UNVERIFIED=$dest
	on_builder 'sudo cat /root/install.iso' >"$dest"
	want=$(on_builder 'sudo sha256sum /root/install.iso' | cut -d' ' -f1)
	have=$(sha256sum "$dest" | cut -d' ' -f1)
	if [ -z "$want" ] || [ "$want" != "$have" ]; then
		echo "copy verification failed; the image was removed" >&2
		exit 1
	fi
	DEST_UNVERIFIED=""
	echo "image ready and verified: $dest"
	echo "It embeds the root password hash: write it to a stick, then delete it."
}

prepare() {
	[ "${PVE_BUILDER:-pve1}" = pve1 ] || {
		echo "prepare writes the stick attached to the hypervisor: it runs on the hypervisor, not on another builder" >&2
		exit 2
	}
	local usb_serial
	usb_serial=${PVE_USB_SERIAL:-$(private_value pve_usb_stick_serial)}
	: "${usb_serial:?pve_usb_stick_serial is missing in private/proxmox/pve1.yaml}"
	trap cleanup EXIT
	render
	upload_answer
	build_remote
	on_builder sudo bash -s -- "$usb_serial" <<'EOF'
set -euo pipefail
usb_serial=$1
echo "--- host: USB stick"
dev=$(readlink -f "/dev/disk/by-id/usb-${usb_serial}")
[ -b "$dev" ] || { echo "stick with serial ${usb_serial} not found"; exit 1; }
[ "$(lsblk -dno TRAN "$dev")" = usb ] || { echo "refusing: $dev is not a USB device"; exit 1; }
# Each guard captures first and tests second: a pipeline into the refusal
# would pass whenever the listing command itself failed.
pv_list=$(pvs --noheadings -o pv_name) || { echo "refusing: cannot list physical volumes"; exit 1; }
case "$pv_list" in *"$dev"*) echo "refusing: $dev is a physical volume"; exit 1 ;; esac
mounts=$(lsblk -nro MOUNTPOINTS "$dev") || { echo "refusing: cannot read the mount points of $dev"; exit 1; }
[ -z "$(printf '%s' "$mounts" | tr -d '[:space:]')" ] || { echo "refusing: $dev is mounted"; exit 1; }
for h in /sys/class/block/"${dev##*/}"/holders /sys/class/block/"${dev##*/}"/*/holders; do
	[ -d "$h" ] || continue
	[ -z "$(ls -A "$h")" ] || { echo "refusing: $dev is in use by another device ($h)"; exit 1; }
done
echo "writing to $dev ($(lsblk -dn -o SIZE,TRAN,MODEL "$dev"))"
dd if=/root/install.iso of="$dev" bs=4M conv=fsync status=none
sync
partprobe "$dev" 2>/dev/null || true
sleep 2
lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
echo "--- host: read the image back from the stick and compare"
size=$(stat -c %s /root/install.iso)
blockdev --flushbufs "$dev"
if ! cmp -n "$size" "$dev" /root/install.iso; then
	echo "the stick's content differs from the image; nothing was armed"
	exit 1
fi
echo "stick content verified"
rm -f /root/install.iso
echo "--- host: one-time boot entry"
# Created outside the boot order (-C) and selected for the next boot only:
# the installer must never be something the firmware falls back to.
for n in $(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} pve-install.*/\1/p'); do efibootmgr -q -B -b "$n"; done
efibootmgr -q -C -d "$dev" -p 2 -L pve-install -l '\EFI\BOOT\BOOTX64.EFI'
id=$(efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} pve-install.*/\1/p' | head -n 1)
[ -n "$id" ] || { echo "the boot entry was not created"; exit 1; }
efibootmgr -q -n "$id"
efibootmgr | grep -E "BootNext|BootOrder|pve-install"
EOF
	echo "media ready and armed for one boot; next: $0 reboot"
	echo "After the install, the hypervisor role wipes the stick and removes the boot entry (just pve-apply)."
}

do_reboot() {
	# The command runs on the host; its substitutions must not expand locally.
	# shellcheck disable=SC2016
	on_builder 'sudo sh -c '"'"'efibootmgr | grep -q "^BootNext:" || { echo "no one-time boot entry armed"; exit 1; }; echo "rebooting into the installer at $(date +%T)"; (sleep 2; reboot) >/dev/null 2>&1 &'"'"''
}

case "${1:-}" in
validate) validate ;;
iso) iso ;;
prepare) prepare ;;
reboot) do_reboot ;;
*)
	echo "usage: $0 validate|iso|prepare|reboot" >&2
	exit 2
	;;
esac
