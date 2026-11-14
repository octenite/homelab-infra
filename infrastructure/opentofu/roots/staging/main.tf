# The staging machine of ADR 0007: a general-purpose Debian VM for a team
# outside the household, in a network of its own. What may reach it and what
# it may reach is enforced outside this file: by the router (E23, E24) and by
# the hypervisor's own firewall file for guest 4010, which the hypervisor
# play writes. What runs on it is the configuration play's and the team's.
module "stg1" {
  source = "../../modules/pve-vm"

  node_name = "pve1"
  # 4010: VLAN 40, host 10. The hypervisor play's firewall file and the tests
  # name the same number (pve_guest_firewalls, scripts/tests/staging.sh).
  vm_id    = 4010
  hostname = "stg1"

  # Literals on purpose: `tofu validate` refuses only what it can see.
  placement    = { pool_id = "staging", vlan_id = 40 }
  ipv4_address = "10.0.40.10/24"
  ipv4_gateway = "10.0.40.1"
  dns_servers  = ["10.0.40.1"]
  dns_domain   = "home.arpa"

  image_file_id   = "local:import/${var.image_file}"
  username        = "ops"
  ssh_public_keys = var.ssh_public_keys

  # The owner's sizing of 2026-11-14 (ADR 0007). Memory is fixed, not a limit:
  # it comes out of the hypervisor's 16 GB whether the machine uses it or not.
  cores      = 2
  memory_mib = 4096
  disk_gib   = 30

  protection    = true
  start_on_boot = true
}

output "vm_id" {
  description = "Guest id of the staging machine."
  value       = module.stg1.vm_id
}
