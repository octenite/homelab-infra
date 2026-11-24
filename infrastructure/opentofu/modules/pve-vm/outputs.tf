output "vm_id" {
  description = "Guest id of the machine."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "network" {
  description = "Where the only network device is attached, read from the resource."
  value = {
    bridge  = one(proxmox_virtual_environment_vm.this.network_device[*].bridge)
    vlan_id = one(proxmox_virtual_environment_vm.this.network_device[*].vlan_id)
  }
}

output "pool_id" {
  description = "Pool the machine was asked into."
  value       = proxmox_virtual_environment_vm.this.pool_id
}
