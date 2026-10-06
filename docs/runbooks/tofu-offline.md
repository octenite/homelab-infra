# Runbook: OpenTofu when the state bucket is unreachable or lost

Use this when `just tofu <root> plan` cannot reach the Backblaze B2 bucket (internet outage, provider outage, key revoked) and a change cannot wait, or when the bucket or its state object is gone.

Status: parts A and B rehearsed on 2026-10-07, three times, while the root held only its marker; the record is at the end. Part C (a new bucket) and "No copy" are not rehearsed.

## What exists

| Item | Where | Notes |
|---|---|---|
| Break-glass copy of the state | `private/opentofu/state-copies/<root>.state.json` | The bucket's object as stored: ciphertext, encrypted by OpenTofu |
| State passphrase | `private/opentofu/b2.sops.yaml`, key `tofu_state_passphrase` | Needed to read the copy |
| Backend settings | `private/opentofu/backend.hcl` | Bucket, region, endpoint |

How the copy is made: after every `apply`, `destroy`, `import`, `refresh`, `taint`, `untaint` and every `state` command that changes something, `scripts/tofu/child.sh` fetches the object from the bucket and replaces the copy. It keeps the previous copy and prints a warning when the object cannot be read or is not an encrypted state. The copy is only as new as the last commit of the private repository that contains it.

The wrapper (`just tofu`) has no offline or restore command. It always talks to the bucket, and it refuses to run while a root holds a backend override. The steps below start OpenTofu directly, with the passphrase taken from the private repository for one command at a time.

## Before starting

- The repository in WSL with the private repository on `main`, and an open session (`just session-start`).
- The state copy of the root. If `private/opentofu/state-copies/<root>.state.json` is missing, stop: see "No copy" at the end.
- Provider plugins already downloaded in the root's `.terraform` directory, if the internet is down. The `pve` root needs none today.
- From Phase 5 the root also needs the hypervisor's API token. The wrapper passes none yet. Extend the commands of part A when it does.

The examples use the root `pve` and start in the repository's top directory.

## A. Work offline from the copy

1. Decide whether the change can wait. A plan against a stale copy proposes to undo whatever was applied after the copy was taken. Compare the copy's commit date with the last apply:

   ```sh
   git -C private log -1 --format=%cd -- opentofu/state-copies/pve.state.json
   ```

2. Put a working copy into the root. The name is ignored by Git. The file stays ciphertext.

   ```sh
   cp private/opentofu/state-copies/pve.state.json infrastructure/opentofu/roots/pve/offline.tfstate
   ```

3. Override the backend with a local one. The encryption block of `versions.tf` stays in force, so the local file stays ciphertext and a wrong passphrase is refused. Git does not ignore the override file: it shows in `git status` until part B removes it, and `just tofu-lint` fails while it exists, so it cannot be merged.

   ```sh
   cat > infrastructure/opentofu/roots/pve/backend_override.tf <<'EOF'
   terraform {
     backend "local" {
       path = "offline.tfstate"
     }
   }
   EOF
   ```

4. Initialise against the local file.

   ```sh
   export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
   sops exec-env private/opentofu/b2.sops.yaml \
     'TF_VAR_state_passphrase="$tofu_state_passphrase" tofu -chdir=infrastructure/opentofu/roots/pve init -reconfigure'
   ```

   Expect `Successfully configured the backend "local"`.

5. Plan. A copy that matches reality gives `No changes`.

   ```sh
   sops exec-env private/opentofu/b2.sops.yaml \
     'TF_VAR_state_passphrase="$tofu_state_passphrase" tofu -chdir=infrastructure/opentofu/roots/pve plan'
   ```

6. Apply only what cannot wait, with the same command and `apply` in place of `plan`. From now on `offline.tfstate` is newer than the bucket. Do not delete it.

While the override file exists, `just tofu` refuses to run and points here. That is on purpose: a plan through the wrapper would look like a plan against the bucket and would not be one.

## B. Return to the bucket

When the bucket answers again:

1. Remove the override.

   ```sh
   rm infrastructure/opentofu/roots/pve/backend_override.tf
   ```

2. If nothing was applied offline, point the root back at the bucket and discard the working copy.

   ```sh
   just tofu pve init -reconfigure
   rm -f infrastructure/opentofu/roots/pve/offline.tfstate infrastructure/opentofu/roots/pve/offline.tfstate.backup
   ```

3. If something was applied offline, move the newer local state into the bucket. OpenTofu says that a state already exists in the new backend and asks "Do you want to overwrite the state in the new backend with the previous state?"; answer `yes`. "Previous" is the local file, "new" is the bucket. The bucket is versioned, so the replaced object stays available as an older version.

   ```sh
   just tofu pve init -migrate-state
   ```

   While it asks, OpenTofu saves both states to temporary files for comparison, in the clear. The wrapper gives every command a private temporary directory in memory (`/dev/shm/tofu.*`, removed when the command ends), because the workstation's disk is not encrypted (X23). Never run this step with OpenTofu started directly. Then remove the working copy as in step 2.

4. Prove the state and refresh the copy. The plan shows no changes. The apply saves a new copy.

   ```sh
   just tofu pve plan
   just tofu pve apply
   ```

   Expect `state copy saved (ciphertext, as stored in the bucket)`.

5. Commit and push the private repository, then check it.

   ```sh
   git -C private add opentofu/state-copies
   git -C private commit -m "OpenTofu state copy after offline work"
   git -C private push
   just private-status
   ```

6. `git status` in the public repository shows no `backend_override.tf`.

## C. The bucket or the object is lost

1. Look for an older version of the object in the Backblaze console first. The bucket is versioned.
2. If the bucket itself is gone, create a new one and a new application key restricted to it. Store both key values and write the new bucket into `private/opentofu/backend.hcl`.

   ```sh
   just secret-set private/opentofu/b2.sops.yaml b2_key_id
   just secret-set private/opentofu/b2.sops.yaml b2_application_key
   ```

3. Do part A, steps 2 to 5. The plan must show no changes before the state goes anywhere.
4. Do part B, steps 1, 3 and 4. `init -migrate-state` writes the local state into the new bucket.
5. Commit the new backend settings, the new key and the state copy together.

   ```sh
   git -C private add opentofu
   git -C private commit -m "OpenTofu state moved to a new bucket"
   git -C private push
   just private-status
   ```

## No copy

Without the bucket object and without a copy there is no state. Today the `pve` root holds one marker resource: initialise the backend again and apply, and the marker is created anew. From Phase 5 every existing VM would have to be imported with `just tofu pve import` before the first plan, or the plan proposes to create them a second time.

## How to know it worked

- `just tofu pve plan` runs against the bucket and shows no changes.
- `private/opentofu/state-copies/pve.state.json` is new, committed and pushed.
- No `backend_override.tf` and no `offline.tfstate` remain in the root.
- The event is recorded in the gate record of the current phase.

## Rehearsal record

2026-10-07, root `pve` holding only its marker, bucket reachable throughout. The offline change was a replacement of the marker (`apply -replace=terraform_data.root`), which touches nothing real.

| Step | Result |
|---|---|
| A.2 to A.5 | Local backend configured on the copy. The plan read the ciphertext and showed no changes |
| The same plan with a wrong passphrase | Refused: "decryption failed for all provided methods" |
| A.6 | Applied. The local state and its backup file stayed ciphertext; the serial went up |
| B.1, B.3 | The question appeared as quoted above; answered `yes`; the bucket took the local state |
| B.4 | The plan against the bucket showed no changes and named the marker created offline. `just tofu pve apply` with nothing to change asked nothing and saved the new copy |
| B.6 | No override and no working copy left; `just tofu-lint` passed |

What the rehearsal changed:

- The two temporary files of the migration were plain text and readable by every user (mode 644). The wrapper now puts them in a private directory in memory by itself (mode 700, files 600, nothing appeared under `/tmp`, nothing left afterwards). Before, this depended on the operator typing `TMPDIR=/dev/shm`.
- The wrapper used to run in offline mode without saying so: `just tofu pve plan` planned against the local file. It now refuses while an override exists.
- The override file is not ignored by Git. `just tofu-lint`, which CI runs, now fails while one exists.

Not rehearsed: part C with a new bucket and a new key, the "No copy" case, and offline work with the internet really down (the provider plugins of a later root must then already be in `.terraform`).
