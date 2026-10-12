resource "proxmox_virtual_environment_container" "this" {
  node_name    = var.node_name
  vm_id        = var.vm_id
  pool_id      = var.placement.pool_id
  unprivileged = true # the provider's default is false; false needs Sys.Modify on /, which the token lacks
  protection   = var.protection
  # Created stopped: what the hypervisor stored is read back before the first
  # start. Starting and stopping is not OpenTofu's business afterwards (see
  # ignore_changes): the container runs only while the laptop travels.
  started       = false
  start_on_boot = var.start_on_boot # the provider's default is true

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_mib
    swap      = var.swap_mib
  }

  disk {
    datastore_id = "local-lvm" # the provider's default is "local", which holds no guest disks
    size         = var.disk_gib
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian" # the default "unmanaged" would leave network, resolver and host name unwritten
  }

  initialization {
    hostname = var.hostname

    # Both written out: what is left unset is copied from the hypervisor's
    # own resolver file, search domain included.
    dns {
      servers = var.dns_servers
      domain  = var.dns_domain
    }

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_gateway
      }
    }

    user_account {
      keys = [for k in var.ssh_public_keys : trimspace(k)]
    }
  }

  # Exactly one device, written out: no dynamic block and no bridge variable,
  # so a second device, another bridge, an empty bridge or a device without a
  # tag cannot be asked for through this module. The firewall flag makes the
  # hypervisor filter the device with the rules of its own file for this
  # guest. No tags: the token may not set them. The MAC address is the one
  # the hypervisor generates: a hardware address does not belong in a public
  # repository, and the hypervisor's MAC filter follows the device by itself.
  network_interface {
    name     = "eth0"
    bridge   = "vmbr0"
    vlan_id  = var.placement.vlan_id
    firewall = true
  }

  # The only feature this module can ask for, and only when the caller says
  # so: every other feature is refused for the token, and none is wanted.
  dynamic "features" {
    for_each = var.nesting ? [true] : []
    content {
      nesting = true
    }
  }

  timeout_create = 300
  timeout_update = 300
  timeout_delete = 180

  lifecycle {
    # The template, root's keys, the pool, "unprivileged" and the disk's
    # storage each force a replacement. The provider would stop the container
    # first and the hypervisor would then refuse to delete a protected one, so
    # the plan fails here instead. A rebuild is a runbook, not a plan.
    prevent_destroy = true
    # A new template pin or a changed key list describes the next build, not
    # this container: neither may ask for a replacement by itself.
    # Ignoring "started" is not a promise that an apply leaves a running
    # container alone: a change of memory, name servers, host name or the
    # network device makes the provider reboot it. Cores, protection and
    # start_on_boot do not.
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
      started,
    ]

    postcondition {
      condition = (
        self.unprivileged &&
        length(self.network_interface) == 1 &&
        self.network_interface[0].bridge == "vmbr0" &&
        self.network_interface[0].vlan_id == var.placement.vlan_id &&
        self.network_interface[0].firewall
      )
      error_message = "The container must be unprivileged, with exactly one network device on vmbr0, its VLAN tag and the firewall flag set."
    }
  }
}
