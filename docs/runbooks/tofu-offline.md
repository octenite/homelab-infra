# Runbook: OpenTofu when the state bucket is unreachable or lost

Use this when `just tofu <root> plan` cannot reach the Backblaze B2 bucket (internet outage, provider outage, key revoked) and a change cannot wait, or when the bucket or its state object is gone.

Status: not rehearsed. The backend is not initialised yet (Phase 3.6 is open), so no state copy exists today. The steps below follow the wrapper scripts and the backend block of `infrastructure/opentofu/roots/pve/versions.tf`. They count as verified once the first rehearsal is recorded. The right moment is directly after the first `just tofu pve apply`, while the root holds only its marker.

## What exists

| Item | Where | Notes |
|---|---|---|
| Break-glass copy of the state | `private/opentofu/state-copies/<root>.state.json` | The bucket's object as stored: ciphertext, encrypted by OpenTofu |
| State passphrase | `private/opentofu/b2.sops.yaml`, key `tofu_state_passphrase` | Needed to read the copy |
| Backend settings | `private/opentofu/backend.hcl` | Bucket, region, endpoint |

How the copy is made: after every `apply`, `destroy`, `import`, `refresh`, `taint`, `untaint` and every `state` command that changes something, `scripts/tofu/child.sh` fetches the object from the bucket and replaces the copy. It keeps the previous copy and prints a warning when the object cannot be read or is not an encrypted state. The copy is only as new as the last commit of the private repository that contains it.

The wrapper (`just tofu`) has no offline or restore command. It always talks to the bucket. The steps below start OpenTofu directly, with the passphrase taken from the private repository for one command at a time.

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

3. Override the backend with a local one. The encryption block of `versions.tf` stays in force.

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

Do not use `just tofu` while the override file exists: its `init` passes the bucket settings, which a local backend rejects.

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

3. If something was applied offline, move the newer local state into the bucket. OpenTofu asks before it overwrites the object; answer `yes`. The bucket is versioned, so the replaced object stays available as an older version.

   ```sh
   TMPDIR=/dev/shm just tofu pve init -migrate-state
   ```

   While it asks, OpenTofu saves both states to a temporary directory for comparison. `TMPDIR=/dev/shm` keeps those files in memory, because the workstation's disk is not encrypted (X23). Then remove the working copy as in step 2.

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
