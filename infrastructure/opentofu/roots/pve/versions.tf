# Root "pve": everything OpenTofu manages on the hypervisor (Phase 5 adds the
# Talos VMs). State lives client-side encrypted in a versioned Backblaze B2
# bucket through the S3 backend; the bucket, endpoint and key come from the
# private backend file, credentials and the passphrase from the environment
# that scripts/tofu/run.sh sets up under `sops exec-env`.

terraform {
  required_version = "~> 1.13"

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

