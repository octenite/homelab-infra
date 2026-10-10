# Runbook: set up the tailnet

Use this once, when the Tailscale network for remote access is created, and again only if it has to be created anew. The design is `docs/adr/0005-administrative-access.md`; the steps it belongs to are R.2 to R.4 of `docs/phases/phase-r-plan.md`.

Status: sections 1 to 3 carried out on 2026-10-09 (step R.2), the devices on 2026-10-10 (R.3), node signing and one rehearsal of the way out on 2026-10-11 (R.4).

## Before starting

- A GitHub account with two-factor login and printed recovery codes. Tailscale cannot check this; it is the owner's precondition.
- The repository in WSL, the private repository on `main`, a session open.
- **No device is logged in to the tailnet yet.** A new tailnet starts with a rule that lets every device reach every other. Step 3 replaces it. Until then the Tailscale client on the laptop and the phone stays logged out.

## 1. The account

1. On the laptop's browser, not the phone's: open `https://login.tailscale.com/start` and sign in with GitHub.
2. Choose the personal account, not an organisation.

The tailnet's name and the permissions GitHub shows on that screen are recorded in the gate record of Phase R.

## 2. The credential for the policy

OpenTofu changes the policy and the settings with an OAuth client that can do only that.

1. In the admin console: **Settings**, then **Trust credentials**, then the button to add a credential, and choose **OAuth**.
2. Give it the description `homelab policy`. Select these scopes and nothing else:

   | Scope | Access |
   |---|---|
   | Policy File | read and write |
   | Feature Settings | read and write |

   The console adds what the policy scope needs by itself: reading the devices and their posture attributes. Select no tags, no keys scope and nothing under "all".
3. The console shows the client's ID and its secret once. Store both, and your login, at the hidden prompts. Nothing is pasted into a chat or a file by hand.

   ```sh
   just secret-set private/tailscale/oauth.sops.yaml tailscale_oauth_client_id
   just secret-set private/tailscale/oauth.sops.yaml tailscale_oauth_client_secret
   just secret-set private/tailscale/oauth.sops.yaml tailscale_owner_login
   ```

   The login is your GitHub user name followed by `@github`, as the console shows it under **Users**.
4. Commit the private repository.

   ```sh
   git -C private add tailscale
   git -C private commit -m "tailnet: OAuth client for the policy root"
   git -C private push
   ```

What this credential can do if it leaks: change the policy among the devices that are already signed, change the settings, and so cut remote access. It cannot add a device, create a key, or change node signing. It does not expire; it is revoked in the same console page.

## 3. The policy and the settings from Git

1. Initialise the root and take over what the console created.

   ```sh
   just tofu tailscale init
   just tofu tailscale import tailscale_acl.policy acl
   just tofu tailscale import tailscale_tailnet_settings.tailnet tailnet_settings
   ```

2. Look at the plan. It replaces the allow-all policy by one without any grant, and sets device approval, user approval, the key expiry of 90 days and automatic updates off.

   ```sh
   just tofu tailscale plan
   ```

   Before a plan and before an apply, `scripts/tofu/child.sh` sends the policy to Tailscale's validation and stops when a test of the policy fails. The provider alone does not: its plan passes with a failing test, and only the save is refused (measured on 2026-10-09, provider 0.29.2).

3. Apply, then plan again.

   ```sh
   just tofu tailscale apply
   just tofu tailscale plan
   ```

   Expected: `No changes.`

4. In the console, under **DNS**, switch **MagicDNS** off. The lab addresses its targets by number, and the laptop takes no name service from Tailscale. This is a step by hand on purpose: the credential of step 2 can neither read nor change the name service (it answers "not found"), and a scope that could would also let a leaked credential point the devices at another name server.

## 4. The devices

The laptop: `docs/components/tailscale-client.md`, "Deployment". The phone: the Tailscale app, signed in with GitHub. Each new device's address goes into `policy.hujson` under `hosts`, with a test of its own, by pull request.

While node signing is off, a new device waits for approval in the console (**Machines**). While it is on, it waits for a signature: section 6.

## 5. Node signing

Node signing ("Tailnet lock") means a device joins only with a signature from a trusted device. The Tailscale service cannot give one, and neither can someone who takes over the GitHub account. The laptop is the only signer (decision D4). First enabled on 2026-10-11.

Before starting: the laptop connected (`tailscale up`), a session open, the password manager open and paper at hand.

1. Check the list of devices. It must hold exactly the devices you know, because enabling signs every device that is in it.

   ```sh
   tailscale status
   tailscale lock status
   ```

   The second prints this laptop's signing key, `tlpub:...`. On the phone, **Settings**, **Tailnet lock** shows the phone's node key and lock key; compare them with **Machines** in the console.
2. Switch device approval off: Tailscale does not allow both. In `infrastructure/opentofu/roots/tailscale/main.tf` set `devices_approval_on = false`, then `just tofu tailscale apply`. From here until step 3 a GitHub login alone adds a device, so go on at once.
3. Enable, **in your own terminal**, with the laptop's key from step 1:

   ```
   tailscale lock init --confirm --gen-disablements 3 tlpub:<this laptop's key>
   ```

   Without `--confirm` the command only prints what it would do. With it, it prints three disablement secrets, once. Do not use `--gen-disablement-for-support`: no secret goes to the vendor.
4. Store the three secrets in the password manager and on one printed copy kept at home. Never in Git, never in a chat, never in a file on the laptop. Close the terminal.
5. Check. Neither command prints a secret; the "disablement values" in the log are hashes.

   ```
   tailscale lock status
   tailscale lock log --limit 3
   ```

   Expected: `Tailnet Lock is ENABLED`, this laptop's key as the only trusted signing key with `(self)`, and no device listed as locked out.

## 6. Signing a new device

On the laptop, connected:

```
tailscale lock status
tailscale lock sign nodekey:<the new device's node key>
```

The first lists devices that wait, with their node keys. Compare the key with what the new device itself shows before signing it. A device can also be signed before it is approved by anything else; without a signature it stays cut off.

## 7. The way out: disabling node signing

Needed when the laptop's Tailscale state is lost (theft, a cleared TPM, a reinstall): no device can then be signed, the laptop included. Rehearsed on 2026-10-11 by the console path of step 1.

1. In the console, from any browser: **Settings**, **Device management**, **Tailnet lock**, **Disable Tailnet lock**. Paste one disablement secret. On a device that is still signed, `tailscale lock disable <secret>` does the same.
2. One used secret switches signing off for the whole tailnet and for good: the others are worthless from then on.
3. At once, by pull request or by hand in the console: `devices_approval_on = true`, so a new device again needs approval.
4. Enrol the laptop again if it was lost (`docs/components/tailscale-client.md`), put its new address into `policy.hujson`, then enable signing anew with section 5. That makes three new secrets; replace the stored ones and destroy the old paper copy.

Without a secret there is no way out: the tailnet has to be deleted and built again.

## How to know it worked

- **Access controls** in the console shows the file from Git, with no grant.
- `just tofu tailscale plan` shows no changes.
- **Machines** is empty.

## If something fails

| Symptom | Cause and action |
|---|---|
| `missing private/tailscale/oauth.sops.yaml` | Step 2.3 was not done |
| The plan fails with a permission error on the settings | The client lacks the Feature Settings scope. Revoke it, create it again with both scopes, store it again |
| `the policy is refused by Tailscale: test(s) failed` | The policy would allow something a test forbids, or a test names a login that does not exist. The lines below the message name the address and what was expected. Nothing was planned or applied |
| `policy.hujson uses a template variable that scripts/tofu/child.sh does not know` | A new `${...}` value was added to the policy. Add it to `tailnet_policy_check` in the same pull request, so the check validates what OpenTofu sends |
| The import says the resource is already managed | It was imported before. Go on with the plan |
