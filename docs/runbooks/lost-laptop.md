# Runbook: the laptop is lost or stolen

Status: written in Phase R step R.11 from the approved plan (`docs/phases/phase-r-plan.md`, "Lost laptop"). **Not yet drilled.** The reduced drill of decision D11 is at the end; until it has run, treat every step here as read, not proven.

The laptop is the operator's workstation. It holds the way into the lab from outside (its place in the tailnet and the only signing key), the operator's SSH key and age key (passphrase-protected, on an unencrypted disk, exception X23), a copy of the private repository, and the backup server VM with its datastore.

## What a finder can do, and what stops it

| The laptop holds | What it opens | What stops it |
|---|---|---|
| Its Tailscale identity, sealed to its TPM | From outside: pve1's SSH and web interface, through the container `remote1`, but only while that container runs | The container runs only between `travel.ps1 -Away` and `-Home` (decision D12). Step 1 below removes it for good |
| The tailnet's only signing key | Signing a new device into the tailnet | A new device also needs a login to the owner's GitHub account, which the laptop does not hold open |
| The SSH key and the age key, each behind a passphrase | pve1 over SSH; every secret in the private repository | The passphrases. From outside, SSH also needs the tunnel, which step 1 closes. At home it needs one of the workstation's two addresses |
| An open operator session, if one was open | The same, with no passphrase, until the session ends | A session lasts 2 hours away and 12 at home, and `-Away` refuses to start with one open |
| The backup server VM and its datastore | pve1's configuration backups, encrypted with a key that is in the private repository | The age key's passphrase |

## Part 1: at once, from the phone or any browser

It needs your GitHub login, with a second factor that is not the laptop. Do the steps in this order: the first one closes the path whatever the laptop still holds.

1. **Tailscale console, Machines: remove `remote1`.** Remote administration is now closed. The container can only come back through a login at home.
2. **GitHub: change the password, end every session (Settings, Sessions), revoke the command-line token** (Settings, Applications, Authorized OAuth Apps, GitHub CLI).
3. **Tailscale console, Machines: remove the laptop.** Then check the list: it must hold the phone and nothing you do not know. Remove anything else.
4. **Tailscale console, Settings, OAuth clients: revoke the policy client.** It could change the policy.
5. **Access controls: compare the policy with Git** (`infrastructure/opentofu/roots/tailscale/policy.hujson` on GitHub). If it differs, somebody changed it: note it and go on; it is put back from Git at home.
6. **healthchecks.io: pause the container's check**, so that its silence does not alert every day.

What stays valid until you are home, and why that is acceptable:

- The laptop's signing key can still sign, but adding a device needs your GitHub login, closed in step 2.
- The SSH key, the age key and the stored secrets reach the lab from nowhere outside once step 1 is done.
- Nothing at home depends on Tailscale: the household notices nothing.

## Part 2: at home

Work from a replacement workstation: `docs/runbooks/restore-workstation.md`, section 3, opens a session there from the recovery keys in the password manager.

1. **The machine list.** In the console it holds exactly the devices you know (the phone).
2. **Node signing without the lost laptop.** Disable it with one disablement secret, then enable it again with the new workstation as the signer: `docs/runbooks/tailnet-setup.md`, sections 7 and 5. Run the commands yourself, in your own terminal: the new disablement secrets are printed once. Store the three new ones in the password manager and on paper; the old ones are spent.
3. **The keys and what they could read.** `docs/runbooks/operator-key-compromised.md`, all of it: a new age key and re-encryption, a new SSH key on all five hosts, then the rotation of every stored secret.
4. **A new policy client.** `docs/runbooks/tailnet-setup.md`, section 2, then `just tofu tailscale apply`: the policy is Git's again.
5. **The new workstation in the tailnet.** `scripts/node2/tailscale.ps1 -Enrol`, then a pull request that replaces the laptop's address in `policy.hujson` (hosts and tests).
6. **The container.** `docs/runbooks/rebuild-remote1.md`: it was removed in part 1, so it is rebuilt and signed by the new workstation.
7. **The backup server.** It was a VM on the lost laptop. `docs/runbooks/restore-workstation.md` rebuilds it empty; pve1's next nightly backup fills it. The old backups are gone with the laptop, and readable only with the age key.
8. **The record.** What was done and when, in the drill log of `DISASTER-RECOVERY.md`.

## How to know it worked

- The console lists only known devices, node signing is on with the new workstation as its only signer, and no device is locked out.
- `just tofu tailscale plan` shows no difference.
- `ssh` with the old key is refused on every host (section 3 of the key runbook proves it per host).
- From a hotspot, after `travel.ps1 -Away` on the new workstation, `just test-outside` passes.

## The reduced drill (decision D11)

Done once, at home, before the laptop first travels with the tunnel in earnest. It runs the steps that have never been run, on the real laptop, and puts everything back.

| Step | For real or on paper |
|---|---|
| Part 1, steps 1 and 3, from the phone: remove `remote1`, then the laptop | For real, timed |
| What the removed laptop can still do: does `tailscale up` bring it back by itself, is it locked out, can it sign itself in again (not documented by the vendor) | For real: this is the drill's finding |
| Part 1, steps 2, 4, 5 and 6 | On paper: find each page on the phone, change nothing |
| Part 2, step 2: disable node signing with a disablement secret, enable it again | For real (the owner's own terminal), new secrets stored |
| Part 2, step 3, section 3 only: a new SSH key on all five hosts | For real |
| Part 2, step 3, the age key and the stored secrets | On paper |
| Part 2, steps 5 and 6: the laptop enrolled again, the policy pull request, the container rebuilt | For real: it is the way back |

It needs the owner at home on the wired workstation for about two hours, the phone, the password manager and the printed secrets. It ends with `just test-remote`, `just test-travel` and a clean `just tofu tailscale plan`. Its record goes into `docs/phases/phase-r.md` and the drill log, and this runbook is corrected by what it finds.
