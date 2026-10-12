# What the module refuses, proven without an API: the provider is a mock and
# every run is a plan. A mock does not apply the provider's defaults, so the
# asserts read only what the module writes out. CI runs this through
# scripts/tofu/lint.sh.
mock_provider "proxmox" {}

variables {
  # The root's own variables.
  template_file   = "debian-13-standard_13.6-1_amd64.tar.zst"
  template_sha512 = "not-read-by-a-test"
  # The module's variables, for the runs that load it directly.
  node_name        = "pve1"
  vm_id            = 9999
  hostname         = "placement-test"
  placement        = { pool_id = "remote", vlan_id = 30 }
  ipv4_address     = "10.0.30.10/24"
  ipv4_gateway     = "10.0.30.1"
  dns_servers      = ["10.0.30.1"]
  dns_domain       = "home.arpa"
  template_file_id = "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  ssh_public_keys  = ["ssh-ed25519 AAAA placement-test-1", "ssh-ed25519 AAAA placement-test-2"]
  cores            = 1
  memory_mib       = 128
  swap_mib         = 0
  disk_gib         = 4
  nesting          = false
  protection       = true
  start_on_boot    = false
}

# The root as committed: whatever main.tf passes, the plan must end on VLAN 30.
run "root_as_committed" {
  command = plan

  assert {
    condition     = module.remote1.network.bridge == "vmbr0" && module.remote1.network.vlan_id == 30
    error_message = "remote1 must be planned on vmbr0 with VLAN tag 30."
  }

  assert {
    condition     = module.remote1.pool_id == "remote"
    error_message = "remote1 must be planned in pool remote."
  }
}

run "tag_30_in_pool_remote_is_planned" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  assert {
    condition     = length(proxmox_virtual_environment_container.this.network_interface) == 1
    error_message = "Exactly one network device."
  }

  assert {
    condition     = proxmox_virtual_environment_container.this.network_interface[0].vlan_id == 30 && proxmox_virtual_environment_container.this.network_interface[0].bridge == "vmbr0"
    error_message = "The device must be on vmbr0 with tag 30."
  }

  assert {
    condition     = proxmox_virtual_environment_container.this.network_interface[0].firewall
    error_message = "The device must carry the firewall flag."
  }

  assert {
    condition     = proxmox_virtual_environment_container.this.unprivileged
    error_message = "The container must be unprivileged."
  }

  assert {
    condition     = length(proxmox_virtual_environment_container.this.features) == 0
    error_message = "No feature is asked for unless the caller sets nesting."
  }
}

run "no_tag_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = null }
  }

  expect_failures = [var.placement]
}

run "tag_0_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = 0 }
  }

  expect_failures = [var.placement]
}

run "tag_1_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = 1 }
  }

  expect_failures = [var.placement]
}

run "tag_10_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = 10 }
  }

  expect_failures = [var.placement]
}

run "tag_31_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = 31 }
  }

  expect_failures = [var.placement]
}

run "tag_50_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = 50 }
  }

  expect_failures = [var.placement]
}

run "pool_talos_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    placement = { pool_id = "talos", vlan_id = 30 }
  }

  expect_failures = [var.placement]
}

run "address_outside_the_zone_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    ipv4_address = "10.0.10.50/24"
  }

  expect_failures = [var.ipv4_address]
}

run "one_key_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-lxc"
  }

  variables {
    ssh_public_keys = ["ssh-ed25519 AAAA only-one"]
  }

  expect_failures = [var.ssh_public_keys]
}
