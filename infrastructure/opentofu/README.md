# OpenTofu

Roots under `roots/` are applied one at a time, from the workstation, with a session open.

| Root | Holds | Since |
|---|---|---|
| `pve` | Everything on the hypervisor: a marker today, the Talos VMs from Phase 5 | Phase 3.6 |

Status: the backend was initialised on 2026-10-07 and the state round trip passed (init, apply, encrypted copy kept, second plan without changes; `docs/phases/phase-3.md`). The root `pve` holds only its marker. Without `private/opentofu/backend.hcl` the wrapper stops and prints the keys the file needs.

## State

- State lives in a versioned Backblaze B2 bucket, through the S3 backend, as the object `<root>/terraform.tfstate`.
- State and plan files are encrypted on the workstation before they leave it: a PBKDF2 key from a passphrase, AES-GCM, `enforced`. OpenTofu refuses to read or write an unencrypted state.
- The bucket has no lock: B2 offers no conditional writes. Run one command at a time, from one terminal.

| What | Where |
|---|---|
| Backend settings and the encryption block | `roots/<root>/versions.tf` |
| Bucket, region, endpoint (identifiers, not secrets) | `private/opentofu/backend.hcl` |
| B2 key (`b2_key_id`, `b2_application_key`) and state passphrase (`tofu_state_passphrase`) | `private/opentofu/b2.sops.yaml` |
| Break-glass copy of the state | `private/opentofu/state-copies/<root>.state.json` |
| Changing the passphrase | `just tofu-passphrase`; [rotate-state-passphrase.md](../../docs/runbooks/rotate-state-passphrase.md) |
| Credentials of a root, beyond the state's | Set by `scripts/tofu/child.sh` for that root only. The roots `pve` and `remote` get the scoped API token of the hypervisor from `private/proxmox/tokens.sops.yaml` |
| The hypervisor's CA certificate | `private/proxmox/pve1-ca.crt`, fetched and proven with `just pve-ca`. The provider has no setting for it, so the wrapper adds it to the system's bundle for the command. Verification is never switched off |

`backend.hcl` holds three settings:

```hcl
bucket    = "<bucket name>"
region    = "<region>"
endpoints = { s3 = "https://s3.<region>.backblazeb2.com" }
```

## The wrapper

```sh
just tofu <root> <command and arguments>
```

For example `just tofu pve plan`. The recipe runs `scripts/tofu/run.sh`, which starts `scripts/tofu/child.sh` under `sops exec-env`. The B2 key and the passphrase exist as environment variables for the lifetime of that one command only.

| Command | What the wrapper does |
|---|---|
| `init` | Runs `tofu init` with `backend.hcl` and the object key of the root. Further arguments are passed on |
| `apply`, `destroy`, `import`, `state`, `taint`, `untaint`, `refresh` | Runs the command, then saves the state copy, also when the command failed half-way. The exit code is OpenTofu's |
| `state list`, `state show`, `state pull` | Runs the command. No copy: they change nothing |
| Anything else, such as `plan`, `validate`, `output` | Passed straight through |

The wrapper refuses to start without the root's directory, without `backend.hcl`, or without an open session.

`tofu state pull` prints the state in the clear. Never redirect it into a file.

## The state copy

After every command that can change state, the wrapper fetches the object from the bucket exactly as it is stored, which is ciphertext, and writes it to `private/opentofu/state-copies/<root>.state.json`. It then says to commit it.

- The copy is accepted only when it carries an `encrypted_data` field and no `resources` field. Otherwise the wrapper prints a warning and leaves the previous copy as it was.
- The private repository's guard (`scripts/check-encrypted.sh` there) refuses anything in that directory that is not an encrypted state.
- The copy is usable offline with a local backend and the same passphrase: [tofu-offline.md](../../docs/runbooks/tofu-offline.md). The wrapper has no command for that, and it refuses to run while a root holds a backend override. The runbook's steps are manual; parts A and B were rehearsed on 2026-10-07.

## Checks

```sh
just tofu-lint
```

It runs `scripts/tofu/lint.sh`: it fails when a backend override file exists anywhere under `infrastructure/opentofu` (a tool of the offline runbook that must never be committed), then `tofu fmt -check -recursive` over `infrastructure/opentofu`, then `tofu init -backend=false` and `tofu validate` in every root. It needs no backend, no session and no secret. It is part of `just lint`, which the CI lint job runs. The pre-commit hook runs only `tofu fmt -check` on the changed `.tf` files.
