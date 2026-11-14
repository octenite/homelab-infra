# What the module refuses, proven without an API: the provider is a mock and
# every run is a plan. A mock does not apply the provider's defaults, so the
# asserts read only what the module writes out. CI runs this through
# scripts/tofu/lint.sh.
mock_provider "proxmox" {}

variables {
  # The root's own variables.
  image_file   = "debian-13-genericcloud-amd64-20261111-2659.qcow2"
  image_sha512 = "not-read-by-a-test"
  # The module's variables, for the runs that load it directly.
  node_name       = "pve1"
  vm_id           = 9999
  hostname        = "placement-test"
  placement       = { pool_id = "staging", vlan_id = 40 }
  ipv4_address    = "10.0.40.10/24"
  ipv4_gateway    = "10.0.40.1"
  dns_servers     = ["10.0.40.1"]
  dns_domain      = "home.arpa"
  image_file_id   = "local:import/debian-13-genericcloud-amd64-20261111-2659.qcow2"
  username        = "ops"
  ssh_public_keys = ["ssh-ed25519 AAAA placement-test-1", "ssh-ed25519 AAAA placement-test-2"]
  cores           = 1
  memory_mib      = 512
  disk_gib        = 4
  protection      = true
  start_on_boot   = false
}

# The root as committed: whatever main.tf passes, the plan must end on VLAN 40.
run "root_as_committed" {
  command = plan

  assert {
    condition     = module.stg1.network.bridge == "vmbr0" && module.stg1.network.vlan_id == 40
    error_message = "stg1 must be planned on vmbr0 with VLAN tag 40."
  }

  assert {
    condition     = module.stg1.pool_id == "staging"
    error_message = "stg1 must be planned in pool staging."
  }
}

run "tag_40_in_pool_staging_is_planned" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.this.network_device) == 1
    error_message = "Exactly one network device."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.this.network_device[0].vlan_id == 40 && proxmox_virtual_environment_vm.this.network_device[0].bridge == "vmbr0"
    error_message = "The device must be on vmbr0 with tag 40."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.this.network_device[0].firewall
    error_message = "The device must carry the firewall flag."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.this.started == false
    error_message = "The machine is created stopped."
  }
}

run "no_tag_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "staging", vlan_id = null }
  }

  expect_failures = [var.placement]
}

run "tag_10_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "staging", vlan_id = 10 }
  }

  expect_failures = [var.placement]
}

run "tag_30_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "staging", vlan_id = 30 }
  }

  expect_failures = [var.placement]
}

run "tag_31_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "staging", vlan_id = 31 }
  }

  expect_failures = [var.placement]
}

run "tag_50_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "staging", vlan_id = 50 }
  }

  expect_failures = [var.placement]
}

run "pool_remote_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "remote", vlan_id = 40 }
  }

  expect_failures = [var.placement]
}

run "pool_talos_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    placement = { pool_id = "talos", vlan_id = 40 }
  }

  expect_failures = [var.placement]
}

run "address_outside_the_zone_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    ipv4_address = "10.0.10.50/24"
  }

  expect_failures = [var.ipv4_address]
}

run "one_key_is_refused" {
  command = plan

  module {
    source = "../../modules/pve-vm"
  }

  variables {
    ssh_public_keys = ["ssh-ed25519 AAAA only-one"]
  }

  expect_failures = [var.ssh_public_keys]
}
