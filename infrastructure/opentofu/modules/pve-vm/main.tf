resource "proxmox_virtual_environment_vm" "this" {
  node_name  = var.node_name
  vm_id      = var.vm_id
  name       = var.hostname
  pool_id    = var.placement.pool_id
  protection = var.protection
  # Created stopped: the hypervisor reads its firewall file for a guest only
  # once the guest exists, so the file is written and read back before the
  # first start. Starting and stopping is not OpenTofu's business afterwards
  # (see ignore_changes).
  started = false
  on_boot = var.start_on_boot

  # A virtual CPU model every x86-64 host of the last decade offers, not the
  # host's own: the guest sees the same CPU after a move to other hardware.
  cpu {
    cores = var.cores
    type  = "x86-64-v2-AES"
  }

  # Fixed: floating = 0 means no balloon device takes memory back.
  memory {
    dedicated = var.memory_mib
    floating  = 0
  }

  # The guest agent is installed by the configuration play, not by the image.
  # The short timeout bounds how long a plan waits for an agent that is not
  # there yet.
  agent {
    enabled = true
    timeout = "1m"
  }

  operating_system {
    type = "l26"
  }

  scsi_hardware = "virtio-scsi-single"

  # The system disk, copied by the hypervisor from the pinned cloud image and
  # grown to its size. No SSH login of the provider is involved.
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = var.image_file_id
    size         = var.disk_gib
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  boot_order = ["scsi0"]

  # Debian's cloud images log to the first serial port.
  serial_device {}

  # cloud-init, from the hypervisor's own generator: host name, one static
  # address, the resolver, one account with keys. No user-data file: that
  # would need a snippets storage and a login the token does not have.
  initialization {
    datastore_id = "local-lvm"

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
      username = var.username
      keys     = [for k in var.ssh_public_keys : trimspace(k)]
    }
  }

  # Exactly one device, written out: no dynamic block and no bridge variable,
  # so a second device, another bridge or a device without a tag cannot be
  # asked for through this module. The firewall flag makes the hypervisor
  # filter the device with the rules of its own file for this guest. The MAC
  # address is the one the hypervisor generates.
  network_device {
    bridge   = "vmbr0"
    model    = "virtio"
    vlan_id  = var.placement.vlan_id
    firewall = true
  }

  timeout_create = 600

  lifecycle {
    # The image and the account's keys each force a replacement, which would
    # delete the disk with everything the machine's users put on it. So the
    # plan fails here instead. A rebuild is a deliberate step, never a plan.
    prevent_destroy = true
    # A new image pin or a changed key list describes the next build, not
    # this machine: neither may ask for a replacement by itself.
    ignore_changes = [
      disk[0].import_from,
      initialization[0].user_account,
      started,
    ]

    postcondition {
      condition = (
        length(self.network_device) == 1 &&
        self.network_device[0].bridge == "vmbr0" &&
        self.network_device[0].vlan_id == var.placement.vlan_id &&
        self.network_device[0].firewall
      )
      error_message = "The machine must have exactly one network device on vmbr0, with its VLAN tag and the firewall flag set."
    }
  }
}
