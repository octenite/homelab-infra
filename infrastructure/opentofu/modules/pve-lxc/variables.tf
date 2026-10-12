variable "placement" {
  description = "Pool and VLAN as one value. The hypervisor does not tie them together (exception X33), so this rule does."
  type = object({
    pool_id = string
    vlan_id = number
  })
  nullable = false

  validation {
    # The list is the policy, one entry per pool. No tag, 0, 1, 10, 31 and 50
    # for the pool "remote" all end in false, and so does every other pool.
    condition = contains(
      ["remote/30"],
      try("${var.placement.pool_id}/${var.placement.vlan_id}", "refused"),
    )
    error_message = "A container in pool \"remote\" carries VLAN tag 30 and no other; no other pool may hold a container."
  }
}

variable "ipv4_address" {
  description = "Static address with its prefix length."
  type        = string
  nullable    = false

  validation {
    condition     = try(cidrhost(var.ipv4_address, 0) == "10.0.30.0" && endswith(var.ipv4_address, "/24"), false)
    error_message = "The address must lie in 10.0.30.0/24."
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
  description = "Host name inside the container."
  type        = string
}

variable "ipv4_gateway" {
  description = "Default gateway."
  type        = string
}

variable "dns_servers" {
  description = "Name servers written into the container."
  type        = list(string)
}

variable "dns_domain" {
  description = "Search domain written into the container."
  type        = string
}

variable "template_file_id" {
  description = "Volume id of the container template, for example local:vztmpl/<file>."
  type        = string
}

variable "ssh_public_keys" {
  description = "Public keys authorised for root, written once at creation."
  type        = list(string)

  validation {
    condition     = length(var.ssh_public_keys) >= 2 && alltrue([for k in var.ssh_public_keys : trimspace(k) != "" && !strcontains(trimspace(k), "\n")])
    error_message = "At least two single-line public keys are required: the lab key and the recovery key."
  }
}

variable "cores" {
  description = "CPU cores."
  type        = number
}

variable "memory_mib" {
  description = "Memory limit in MiB. A limit, not a reservation."
  type        = number
}

variable "swap_mib" {
  description = "Swap in MiB."
  type        = number
}

variable "disk_gib" {
  description = "Root disk in GiB, thin, on local-lvm."
  type        = number
}

variable "nesting" {
  description = "The hypervisor's nesting feature: the container sees its own /proc and /sys writable, which newer systemd releases expect. It can be set at creation only."
  type        = bool
}

variable "protection" {
  description = "The hypervisor's protection flag: a protected container cannot be deleted."
  type        = bool
}

variable "start_on_boot" {
  description = "Whether the hypervisor starts the container at boot."
  type        = bool
}
