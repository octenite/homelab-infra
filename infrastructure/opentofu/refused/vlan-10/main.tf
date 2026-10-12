# This configuration must FAIL `tofu validate`: a container asked into the
# management VLAN. scripts/tofu/lint.sh expects the refusal, and fails when
# it validates or fails for another reason.
terraform {
  required_version = "~> 1.13"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
    }
  }
}

module "refused" {
  source = "../../modules/pve-lxc"

  node_name        = "pve1"
  vm_id            = 9999
  hostname         = "refused"
  placement        = { pool_id = "remote", vlan_id = 10 }
  ipv4_address     = "10.0.30.10/24"
  ipv4_gateway     = "10.0.30.1"
  dns_servers      = ["10.0.30.1"]
  dns_domain       = "home.arpa"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_keys  = ["ssh-ed25519 AAAA refused-1", "ssh-ed25519 AAAA refused-2"]
  cores            = 1
  memory_mib       = 128
  swap_mib         = 0
  disk_gib         = 4
  nesting          = false
  protection       = true
  start_on_boot    = false
}
