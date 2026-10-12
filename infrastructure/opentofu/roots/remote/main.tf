# The administration container of Phase R: Tailscale's subnet router for the
# hypervisor's SSH and web interface, and nothing else. What may reach it and
# what it may reach is enforced outside this file: by the router (E15 to
# E17), by the hypervisor's own firewall file for guest 3010 (written by the
# hypervisor play, not by this root: the token could remove it either way,
# and the play checks it with a credential a stolen token does not give),
# and by the Tailscale policy.
module "remote1" {
  source = "../../modules/pve-lxc"

  node_name = "pve1"
  # 3010: VLAN 30, host 10. The hypervisor play's firewall file and the tests
  # name the same number (pve_guest_firewalls, scripts/tests/remote.sh).
  vm_id    = 3010
  hostname = "remote1"

  # Literals on purpose: `tofu validate` refuses only what it can see.
  placement    = { pool_id = "remote", vlan_id = 30 }
  ipv4_address = "10.0.30.10/24"
  ipv4_gateway = "10.0.30.1"
  dns_servers  = ["10.0.30.1"]
  dns_domain   = "home.arpa"

  template_file_id = "local:vztmpl/${var.template_file}"
  ssh_public_keys  = var.ssh_public_keys

  cores      = 1
  memory_mib = 256
  swap_mib   = 0
  disk_gib   = 4

  nesting    = false
  protection = true
  # It runs only while the laptop travels (decision D12); travel.ps1 starts
  # and stops it.
  start_on_boot = false
}

output "vm_id" {
  description = "Guest id of the administration container."
  value       = module.remote1.vm_id
}
