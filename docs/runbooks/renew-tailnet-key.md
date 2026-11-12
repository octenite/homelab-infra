# Runbook: renew the laptop's or the phone's place in the tailnet

Status: written in Phase R step R.11. **Not yet run:** the first key expires on 2027-01-08 (the laptop, enrolled 2026-10-10), the phone's about then (read it in the console). The steps marked "to verify" are read from the vendor's documentation and from the client's source, not seen in this lab; the first renewal at home verifies them and corrects this runbook (backlog B58).

The owner's devices hold a key that expires after 90 days (decision D7). The container's key does not expire (exception X27). An expired device is still listed but cannot connect until its owner signs in again.

## The rule: renew at home, before the trip

`travel.ps1 -Away` reads the laptop's expiry and warns from 14 days before it. When it warns, or before any trip that runs past the date (`tailscale status --json`, field `Self.KeyExpiry`), renew at home:

1. Run everything as the Windows user who owns the Tailscale profile, never elevated to another account and never as SYSTEM.
2. `tailscale up --force-reauth` with every setting named. The client prints the full command when a bare `tailscale up` is refused; it contains `--shields-up` and `--accept-dns=false`. Use exactly that command with `--force-reauth` added. Do not use `tailscale login`: it creates a new device with a new address.
3. Sign in with GitHub in the browser page it opens.
4. **To verify:** the renewal gives the laptop a new node key. The laptop is the tailnet's signer, and the vendor's documentation says a device whose own signing key is trusted signs its new node key itself. Read it: `tailscale lock status` must show no device locked out, the laptop included. If the laptop shows as locked out, sign it from itself: `tailscale lock sign nodekey:<the key it prints>`.
5. `tailscale down`, then `powershell -File scripts\node2\tailscale.ps1 -Check`: the settings and the sealed state are as before.
6. The address stays the same after a renewal. If the console shows a new address, a new device was created: remove the old entry and send a pull request for `policy.hujson`.
7. Check the new date: `tailscale status --json`, `Self.KeyExpiry`, 90 days ahead.

The phone: in the app, the account menu, "Reauthenticate", at home. Then, on the laptop, `tailscale lock status`: if the phone is locked out, sign its new key (`docs/runbooks/tailnet-setup.md`, section 6).

## If the key expires while away

It needs internet and the GitHub login, whose second factor is on the phone.

1. `travel.ps1 -Connect` fails, or the client's icon asks for a login. `ssh ops@10.0.10.10` times out.
2. Steps 2 to 4 above, on whatever network the laptop has.
3. `travel.ps1 -Connect`, then `ssh ops@10.0.10.10 true`.
4. **If step 4 above leaves the laptop locked out and it cannot sign itself:** nothing repairs that from the road. No other device can sign (the phone cannot, and the container is not a signer by decision D4), and disabling node signing needs a disablement secret typed on a signed device. Remote administration then waits until you are home; nothing at home is affected.
5. Do not, to get in, switch node signing off from the console with a disablement secret while away: it leaves the tailnet open to any device that can log in as you until you are home.

A shorter way exists and is not taken: the console can switch a device's key expiry off. It removes the check that D7 asked for, on the device that holds the signing key.

## How to know it worked

- `tailscale status --json` shows `Self.KeyExpiry` about 90 days ahead and `BackendState` `Running` after `-Connect`.
- `tailscale lock status` shows nothing locked out.
- The policy needed no change (`just tofu tailscale plan` shows none), because the address is the same.
