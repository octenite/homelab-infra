# Secrets register

One row per secret or key: where it lives, who owns it, when it rotates, and how. The values themselves are never written here. Custody rules and the reasoning are in [ARCHITECTURE.md](../ARCHITECTURE.md) section 9.

Owner of every row today: the repository owner, who is the only administrator.

| Secret | Created | Lives in | Protects | Rotation | Procedure |
|---|---|---|---|---|---|
| age operator key | 2026-10-05 | Workstation, WSL2: `~/.config/sops/age/operator.age`, passphrase-encrypted | Every SOPS file in the private repository | Yearly; at once if the laptop is lost or the passphrase may be known | [bootstrap-keys.md](../runbooks/bootstrap-keys.md) |
| age recovery key | 2026-10-05 | Password manager and paper copies; never on the workstation | Every SOPS file, when the operator key is gone | On exposure | [bootstrap-keys.md](../runbooks/bootstrap-keys.md) |
| Lab SSH key | 2026-10-05 | Workstation, WSL2: `~/.ssh/homelab_ed25519`, passphrase-protected; loaded into an in-memory agent per session | Root access to the router, both access points and the hypervisor | Yearly; at once if the laptop is lost | New key pair; Ansible replaces the authorised key on every host |
| Recovery SSH key | 2026-10-05 | Private half in the password manager only, with its passphrase; public half authorised on the router and both access points | Root access to the network devices when the lab key is lost | On use, or on exposure | New key pair created in memory; `just openwrt-ssh-keys` |
| Wi-Fi keys: main, guest, IoT | 2026-10-05 (main and IoT generated; guest is the key in use before the split) | Private repository, `ansible/inventory/group_vars/openwrt/wifi.sops.yaml` | Access to each wireless network | Main and IoT: when a device that knew them is lost or sold. Guest: at will | Edit with `sops`, then apply with Ansible |
| Router configuration backups | 2026-10-05 | Private repository, `openwrt/backups/`, SOPS-encrypted | Contain Wi-Fi keys, SSH host keys and password hashes of the network devices | Not rotated; superseded by the next backup | `private/openwrt/backups/README.md` |
| GitHub CLI token | Before the project | Workstation, WSL2, in a readable file | Push access to both repositories | Owner will replace it with a fine-grained token limited to the two repositories | Known gap against exception X23, accepted for now (see `docs/phases/phase-1.md`) |
| OpenWrt root passwords | Before the project | Owner | Console and LuCI login on the three network devices | When Phase 2 moves them into SOPS | Phase 2 |
| Proxmox `root@pam` password | Before the project | Owner | The current hypervisor install, which Phase 3 replaces | Replaced by the reinstall | Phase 3 |

Not yet created, added when they exist: the recovery SSH key, the OpenTofu state passphrase, API tokens for Proxmox, Cloudflare and the storage provider, backup repository passwords, the OpenBao seal key, the Talos secrets bundle.
