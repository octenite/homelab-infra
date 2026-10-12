output "vm_id" {
  description = "Guest id of the container."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "network" {
  description = "Where the only network device is attached, read from the resource."
  value = {
    bridge  = one(proxmox_virtual_environment_container.this.network_interface[*].bridge)
    vlan_id = one(proxmox_virtual_environment_container.this.network_interface[*].vlan_id)
  }
}

output "pool_id" {
  description = "Pool the container was asked into. The provider does not read it back; scripts/tests/remote.sh does."
  value       = proxmox_virtual_environment_container.this.pool_id
}
