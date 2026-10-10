# The whole policy file of the tailnet. The resource replaces whatever is
# there, and the Tailscale API validates it, tests included, at plan time: a
# failing test fails the plan. The file is HuJSON; its comments are kept.
resource "tailscale_acl" "policy" {
  acl = templatefile("${path.module}/policy.hujson", {
    owner_login = var.owner_login
  })
}

# Settings of the tailnet. What is not listed here is left as it is.
resource "tailscale_tailnet_settings" "tailnet" {
  # Off since step R.4: node signing replaces it, and Tailscale does not
  # allow both. A new device now needs a signature from the laptop, which
  # the Tailscale service itself cannot give. If node signing is ever
  # disabled for longer than the rehearsal of a recovery, this goes back to
  # true in the same change (docs/runbooks/tailnet-setup.md).
  devices_approval_on = false

  # Versions are pinned and bumped by pull request.
  devices_auto_updates_on = false

  # Decision D7: the owner's devices log in again every 90 days.
  devices_key_duration_days = 90

  # A person who is invited later cannot join without approval.
  users_approval_on = true

  # Edits in the web console stay possible: closing must work from any
  # browser in an emergency. `just tofu tailscale plan` shows any difference
  # from Git afterwards.
  acls_externally_managed_on = false
}
