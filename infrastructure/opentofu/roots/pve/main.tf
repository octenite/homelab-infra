# Phase 3.6: the backend round trip (init, apply, read the state back) is proven with
# this marker alone. Phase 5 replaces it with the Talos VM module.
resource "terraform_data" "root" {
  input = "pve"
}

output "root" {
  description = "Name of this root, as recorded in state."
  value       = terraform_data.root.output
}
