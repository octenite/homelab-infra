# Runbook: the phone is lost or stolen

Status: written in Phase R step R.11 for the phone as it is today. Not drilled. The household plan (`docs/phases/phase-r-household-plan.md`, "Lost phone") gives the phone its first grant and then extends this runbook and drills it (step H.7).

## What the phone holds today

| On the phone | What it opens | What stops it |
|---|---|---|
| A place in the tailnet | Nothing: no grant names the phone as a source, and `just test-outside phone` proved on 2026-11-03 that it reaches neither pve1, the container nor the laptop. It holds no signing key: an Android phone cannot sign | The policy and its tests |
| The password manager and the authenticator, each behind its own PIN | The GitHub login with its second factor (exception X32), and with it the Tailscale console; pve1's passwords and second factor; the recovery keys and the disablement secrets | The phone's lock and the two app PINs. No GitHub or Tailscale session is left standing on the phone |
| Telegram | The alerts of the lab, and the bot's chat | The phone's lock |

So a lost phone is first of all a lost second factor and a lost password store. The lab itself is not reachable from it.

## At once, from the laptop or any browser

In this order:

1. **The password manager and the authenticator: end the phone's sessions** from their web pages. They hold the GitHub login, so they come first. An app that is already unlocked keeps what it has stored until it next connects.
2. **GitHub: change the password and end every session.** With this closed, the next steps cannot be undone from the phone.
3. **Tailscale console, Machines: remove the phone.**
4. **The machine list holds only known devices**, and `just tofu tailscale plan` shows no difference. If it shows one, `just tofu tailscale apply` puts Git's policy back.
5. **Telegram: end the phone's session** (Settings, Devices) from another device.

## If either app may have been unlocked

Treat what it held for the lab as exposed, and replace it at home:

| What | How |
|---|---|
| The recovery SSH key and the recovery age key | `docs/runbooks/operator-key-compromised.md`: the recovery keys are replaced with the operator's |
| The disablement secrets | `docs/runbooks/tailnet-setup.md`, section 7 then 5: disable node signing with one, enable it again, store the three new ones |
| pve1's passwords and second factor | The web interface, then `docs/security/secrets-register.md` for each row |
| The GitHub recovery codes | GitHub, Settings, Password and authentication: generate new ones, print them |

## The new phone

1. Install the password manager and the authenticator, each with its own PIN (the conditions of X32).
2. Tailscale: sign in with GitHub. The device is locked out until it is signed: on the laptop, `tailscale lock sign nodekey:<its key>` (`docs/runbooks/tailnet-setup.md`, section 6). Disconnect it again: at home the clients stay disconnected.
3. A pull request that replaces the phone's address in `infrastructure/opentofu/roots/tailscale/policy.hujson` (hosts and deny tests), applied with `just tofu tailscale apply`.
4. healthchecks.io and Telegram: sign in; the alert channels belong to the accounts, not to the phone.

## How to know it worked

- The console lists the laptop, the new phone and, while it exists, `remote1`; nothing is locked out.
- `just tofu tailscale plan` shows no difference.
- On the next trip, `just test-outside phone` passes with the new phone.
