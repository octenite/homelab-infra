# Runbook: change the OpenTofu state passphrase

Use this when the passphrase that encrypts the OpenTofu state may be known to someone else, or after the workstation was lost. It is not rotated routinely.

Status: rehearsed on 2026-10-09 with the marker state of the root `pve`, to a generated passphrase and back. The record is at the end.

## What it does

Every root's state is encrypted on the workstation with a key derived from one passphrase. OpenTofu keeps what it needs to derive the key again under the name of the key slot that wrote the state, and the slot that writes has to be named in the code. So a root has two slots, `state` and `state_alt`:

| Slot named in `method` | The other slot |
|---|---|
| Writes, with the current passphrase | Is the fallback for reading, with the previous passphrase |

A rotation swaps the two slots and the two passphrases. The next apply reads the state through the fallback and writes it with the new passphrase. At no point is there a state that cannot be read, and until the last step there is a way back.

Outside a rotation no previous passphrase is stored, and the wrapper gives both slots the current one.

## Before starting

- The repository in WSL, the private repository on `main` and in step with GitHub (`just private-status`), a session open.
- Every root initialised on this workstation (`just tofu <root> init`) and applied without pending changes.
- No backend override in any root. This is not the offline procedure.

## Steps

1. See where things stand. Every root must read with the current passphrase alone.

   ```sh
   just tofu-passphrase status
   ```

2. Begin. The current passphrase becomes the previous one, a new one is generated and stored, and the two slots swap in every root's `versions.tf`.

   ```sh
   just tofu-passphrase begin
   ```

   To type a passphrase of your own at a hidden prompt, 16 characters or more: `just tofu-passphrase begin --prompt`.

3. Apply every root. Nothing changes in the lab; the state is written again, now with the new passphrase. Each apply also refreshes the copy in the private repository.

   ```sh
   just tofu pve apply
   ```

   Expected: `Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` and `state copy saved`.

4. Check. Every root must read with the new passphrase alone.

   ```sh
   just tofu-passphrase status
   ```

5. Copy the new passphrase into the password manager.

   ```sh
   just reveal private/opentofu/b2.sops.yaml tofu_state_passphrase
   ```

6. Finish. The tool checks step 4 again and only then forgets the previous passphrase.

   ```sh
   just tofu-passphrase finish
   ```

7. Commit. The private repository holds the new passphrase and the re-encrypted state copies. The public repository holds the swapped slots, as a pull request.

   ```sh
   git -C private add opentofu
   git -C private commit -m "OpenTofu state passphrase rotated"
   git -C private push
   ```

Do steps 2 to 7 in one sitting. Between `begin` and the merge of the pull request, a checkout of `main` has the slots the other way round and cannot read the state.

## The way back

Before `finish`, a rotation can be undone at any step:

```sh
just tofu-passphrase back
just tofu pve apply          # every root
just tofu-passphrase finish
```

`back` swaps the passphrases and the slots again. The earlier passphrase is current, and the newer one is the fallback until `finish`.

## If something fails

| Symptom | Cause and action |
|---|---|
| `begin`: "not every state reads with the current passphrase" | A root is not initialised here, or an earlier rotation was left unfinished. `just tofu-passphrase status` names the root. Nothing was changed |
| An apply fails with "decryption failed for all provided methods" | The slots in `versions.tf` and the stored passphrases do not belong together, usually because `versions.tf` was edited by hand or another branch is checked out. `python3 scripts/tofu/flip-slot.py --show <versions.tf>` prints the slot that writes. Nothing was written; go back |
| `finish` refuses | A root was not applied since `begin`. Apply it. The previous passphrase is kept until every root reads without it |
| The bucket is unreachable | Wait, or go back. Do not combine this with the offline procedure |

## What the old passphrase can still read

- Every state object version that the bucket keeps from before the rotation.
- Every state copy in the history of the private repository from before the rotation.

If the old passphrase is treated as known, those are treated as read. The state holds what OpenTofu manages: today a marker; from Phase R the containers' settings; later the cluster's machine configuration, which contains secrets. Rotating those secrets is then part of the same incident, by `docs/runbooks/operator-key-compromised.md`.

## How to know it worked

- `just tofu-passphrase status` says "no rotation under way" and every root reads with the current passphrase alone.
- `just tofu <root> plan` shows no changes in every root.
- The password manager holds the new passphrase.
- Both repositories are committed and pushed.

## Rehearsal record

2026-10-09, root `pve` with its marker only.

| Step | Result |
|---|---|
| `begin` | A generated passphrase became current; the slot that writes changed from `state` to `state_alt` |
| `status` before the apply | The state did not read with the new passphrase alone, as expected |
| `apply` | 0 added, 0 changed, 0 destroyed; the state was written again and its copy saved |
| `status` after the apply | Read with the new passphrase alone |
| The old passphrase alone | Refused: "decryption failed for all provided methods" |
| `back`, `apply`, `finish` | The original passphrase is current again, the slot that writes is `state`, the rehearsal passphrase alone is refused, the plan shows no changes |

Two designs were tried first and failed in the same rehearsal, without harm to the state. A fallback slot under another name cannot read a state, because OpenTofu looks for the salt under the slot's own name. Pointing both slots at one name is refused with "Duplicate metadata key". Choosing the writing slot by a variable is refused too: the method must be named statically. Hence the swap in the code.
