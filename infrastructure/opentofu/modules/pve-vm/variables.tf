variable "placement" {
  description = "Pool and VLAN as one value. The hypervisor does not tie them together (exception X33), so this rule does."
  type = object({
    pool_id = string
    vlan_id = number
  })
  nullable = false

  validation {
    # The list is the policy, one entry per pool. Every other pool and every
    # other tag, none included, ends in false.
    condition = contains(
      ["staging/40"],
      try("${var.placement.pool_id}/${var.placement.vlan_id}", "refused"),
    )
    error_message = "A virtual machine in pool \"staging\" carries VLAN tag 40 and no other; no other pool may hold one through this module."
  }
}

variable "ipv4_address" {
  description = "Static address with its prefix length."
  type        = string
  nullable    = false

  validation {
    condition     = try(cidrhost(var.ipv4_address, 0) == "10.0.40.0" && endswith(var.ipv4_address, "/24"), false)
    error_message = "The address must lie in 10.0.40.0/24."
  }
}

variable "node_name" {
  description = "Hypervisor node."
  type        = string
}

variable "vm_id" {
  description = "Guest id. Fixed in code: the hypervisor's firewall file and the tests name it."
  type        = number
}

variable "hostname" {
  description = "Host name inside the machine."
  type        = string
}

variable "ipv4_gateway" {
  description = "Default gateway."
  type        = string
}

variable "dns_servers" {
  description = "Name servers written by cloud-init."
  type        = list(string)
}

variable "dns_domain" {
  description = "Search domain written by cloud-init."
  type        = string
}

variable "image_file_id" {
  description = "Volume id of the cloud image the disk is imported from, for example local:import/<file>."
  type        = string
}

variable "username" {
  description = "The account cloud-init creates at the first boot, with the keys below and sudo."
  type        = string
}

variable "ssh_public_keys" {
  description = "Public keys authorised for that account, written once at creation."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) >= 2 && alltrue([for k in var.ssh_public_keys : trimspace(k) != "" && !strcontains(trimspace(k), "\n")])
    error_message = "At least two single-line public keys are required: the lab key and the recovery key."
  }
}

variable "cores" {
  description = "Virtual CPU cores."
  type        = number
}

variable "memory_mib" {
  description = "Memory in MiB, fixed: no ballooning."
  type        = number
}

variable "disk_gib" {
  description = "System disk in GiB, thin, on local-lvm."
  type        = number
}

variable "protection" {
  description = "The hypervisor's protection flag: a protected machine and its disks cannot be deleted."
  type        = bool
}

variable "start_on_boot" {
  description = "Whether the hypervisor starts the machine at boot."
  type        = bool
}
