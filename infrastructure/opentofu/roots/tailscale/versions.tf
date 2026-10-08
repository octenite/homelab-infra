# Root "tailscale": the access policy and the settings of the tailnet that
# carries remote access (docs/adr/0005-administrative-access.md). Nothing here
# creates a device or a key: devices join by an interactive login, and node
# signing is a command-line matter (docs/phases/phase-r-plan.md).
# State lives client-side encrypted in the same bucket as the other roots.

terraform {
  required_version = "~> 1.13"

  required_providers {
    # Exact pin; Renovate proposes the bumps. The lock file beside this file
    # holds the checksums.
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.29.2"
    }
  }

  backend "s3" {
    # bucket, region and endpoints: private/opentofu/backend.hcl. The object
    # key is <root>/terraform.tfstate, passed by scripts/tofu/run.sh.
    # Backblaze B2 is S3-compatible but not AWS: no STS, no account id, no
    # region validation, no conditional writes for a lock file.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = false
  }

  # State and plan files never leave this machine unencrypted; "enforced"
  # refuses to read or write an unencrypted state.
  #
  # Two key slots, "state" and "state_alt". The slot named in `method` writes,
  # with the current passphrase. The other is the fallback for reading, with
  # the previous passphrase, which exists only while a rotation is under way;
  # otherwise the wrapper passes the current passphrase for both, so there is
  # one key and no second way in. OpenTofu keeps a key's salt under the
  # slot's name and wants the writing method named statically, so a rotation
  # swaps the two slots: scripts/tofu/passphrase.sh does it, never by hand
  # (docs/runbooks/rotate-state-passphrase.md).
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    key_provider "pbkdf2" "state_alt" {
      passphrase = var.state_passphrase_previous
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    method "aes_gcm" "state_alt" {
      keys = key_provider.pbkdf2.state_alt
    }
    state {
      method = method.aes_gcm.state
      fallback {
        method = method.aes_gcm.state_alt
      }
      enforced = true
    }
    plan {
      method = method.aes_gcm.state
      fallback {
        method = method.aes_gcm.state_alt
      }
      enforced = true
    }
  }
}

variable "state_passphrase" {
  description = "Passphrase that encrypts state and plan files (TF_VAR_state_passphrase, from the private repository)."
  type        = string
  sensitive   = true
}

variable "state_passphrase_previous" {
  description = "Passphrase a state may still be encrypted with during a rotation (TF_VAR_state_passphrase_previous). Equal to the current one otherwise."
  type        = string
  sensitive   = true
}

variable "owner_login" {
  description = "The owner's login in the tailnet, as the policy file writes it. An identifier, kept in the private repository (TF_VAR_owner_login)."
  type        = string
}

# The credential is an OAuth client limited to the policy file and the feature
# settings (TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_CLIENT_SECRET, set by
# scripts/tofu/child.sh for this root only). It cannot add a device, create a
# key or touch node signing. The tailnet is the one that owns the credential.
provider "tailscale" {}
