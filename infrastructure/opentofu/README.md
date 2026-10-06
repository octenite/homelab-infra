# OpenTofu

Roots under `roots/` are applied one at a time with `just tofu <root> <command>`, which runs `scripts/tofu/run.sh`: the Backblaze B2 credentials and the state passphrase come from `private/opentofu/b2.sops.yaml` for the lifetime of the command only (`sops exec-env`), and the bucket, key and endpoint from `private/opentofu/backend.hcl`.

| Root | Holds | Since |
|---|---|---|
| `pve` | everything on the hypervisor: a marker today, the Talos VMs from Phase 5 | Phase 3.6 |

State and plan files are client-side encrypted (PBKDF2 passphrase, AES-GCM, `enforced`) before they reach the bucket, which is versioned. After every apply the encrypted state is pulled into `private/opentofu/state-copies/` and committed: the break-glass copy for a WAN outage, usable with a local backend override (see `docs/runbooks/tofu-offline.md` when it exists).

Checks: `just tofu-lint` (formatting and `validate` of every root without a backend) runs in `just lint` and in CI.
