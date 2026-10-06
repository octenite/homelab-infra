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
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

variable "state_passphrase" {
  description = "Passphrase that encrypts state and plan files (TF_VAR_state_passphrase, from the private repository)."
  type        = string
  sensitive   = true
}
