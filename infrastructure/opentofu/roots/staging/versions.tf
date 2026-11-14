# Root "staging": the staging machine of ADR 0007 on the hypervisor
# (docs/adr/0007-staging-vm.md). A root of its own, so its state and its
# plans are separate from the lab's other guests. State lives client-side
# encrypted in the versioned bucket through the S3 backend; the bucket,
# endpoint and key come from the private backend file, credentials and the
# passphrase from the environment that scripts/tofu/run.sh sets up under
# `sops exec-env`.

terraform {
  required_version = "~> 1.13"

  required_providers {
    # Exact pin; Renovate proposes the bumps. The lock file beside this file
    # holds the checksums.
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.116.0"
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
  # refuses to read or write an unencrypted state. The two key slots are
  # explained in roots/remote/versions.tf; scripts/tofu/passphrase.sh swaps
  # them in every root during a rotation, never by hand.
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

variable "pve_endpoint" {
  description = "API address of the hypervisor. Reached from the workstation's pinned addresses (E2)."
  type        = string
  default     = "https://10.0.10.10:8006/"
}

variable "image_file" {
  description = "File name of the pinned cloud image in the import directory of the storage local (image.auto.tfvars.json)."
  type        = string
}

# OpenTofu cannot check a file on the hypervisor. The value is here so that
# the pin is one file: scripts/tofu/template-pin.sh reads it and compares it
# with the file on the host before a plan and after an apply, and
# scripts/tofu/lint.sh compares it with the hypervisor play's pin.
variable "image_sha512" {
  description = "SHA-512 of that file."
  type        = string
}

variable "ssh_public_keys" {
  description = "Keys authorised for the first account at creation (TF_VAR_ssh_public_keys, the operator's key list from the private repository)."
  type        = list(string)
}

# The API token comes from the environment (PROXMOX_VE_API_TOKEN), set by
# scripts/tofu/child.sh. The certificate is verified against the hypervisor's
# own CA; `insecure` is never set. No SSH block: the token is the only way in.
provider "proxmox" {
  endpoint = var.pve_endpoint
}
