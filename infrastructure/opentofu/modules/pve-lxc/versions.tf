# Module "pve-lxc": one unprivileged container on the hypervisor, placed by a
# rule that `tofu validate` enforces. Guests are created through modules
# only; scripts/tofu/lint.sh refuses a root that declares one directly.

terraform {
  required_version = "~> 1.13"

  required_providers {
    # The same exact pin as the roots; Renovate moves them together.
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
    }
  }
}
