# Phase 3.6: the backend round trip (init, apply, read the state back) is proven with
# this marker alone. Phase 5 replaces it with the Talos VM module.
resource "terraform_data" "root" {
  input = "pve"
}

output "root" {
  description = "Name of this root, as recorded in state."
  value       = terraform_data.root.output
}

# Phase R, step R.1: two reads through the scoped token prove the provider,
# the token and the certificate check before anything is created with them.
data "proxmox_version" "pve" {}

data "proxmox_virtual_environment_pool" "talos" {
  pool_id = "talos"
}

output "pve_version" {
  description = "Version the hypervisor's API reports to the token."
  value       = data.proxmox_version.pve.version
}

output "pool_talos_members" {
  description = "Number of guests in the pool the token may manage."
  value       = length(data.proxmox_virtual_environment_pool.talos.members)
}
