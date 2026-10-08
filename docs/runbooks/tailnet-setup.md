# Runbook: set up the tailnet

Use this once, when the Tailscale network for remote access is created, and again only if it has to be created anew. The design is `docs/adr/0005-administrative-access.md`; the steps it belongs to are R.2 to R.4 of `docs/phases/phase-r-plan.md`.

Status: steps 1 to 3 written for step R.2 on 2026-10-09. The parts for devices and node signing are added with steps R.3 and R.4.

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

   Tailscale checks the policy and its tests while planning. A failing test fails the plan.

3. Apply, then plan again.

   ```sh
   just tofu tailscale apply
   just tofu tailscale plan
   ```

   Expected: `No changes.`

4. In the console, under **DNS**, switch **MagicDNS** off. The lab addresses its targets by number, and the laptop takes no name service from Tailscale.

## How to know it worked

- **Access controls** in the console shows the file from Git, with no grant.
- `just tofu tailscale plan` shows no changes.
- **Machines** is empty.

## If something fails

| Symptom | Cause and action |
|---|---|
| `missing private/tailscale/oauth.sops.yaml` | Step 2.3 was not done |
| The plan fails with a permission error on the settings | The client lacks the Feature Settings scope. Revoke it, create it again with both scopes, store it again |
| The plan fails on a test of the policy | The policy would allow something a test forbids, or a test names a login that does not exist. The message names the test. Nothing was applied |
| The import says the resource is already managed | It was imported before. Go on with the plan |
