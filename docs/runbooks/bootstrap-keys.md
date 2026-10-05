# Runbook: create the operator and recovery keys

Purpose: create the two age identities that every SOPS file is encrypted to, without a private key ever being written to disk in readable form. The workstation's disks are not encrypted (exception X23), so this matters.

Who: the owner, once, in a WSL terminal inside the repository (so the pinned `age` is on the path). Nobody else can do this step, because it needs a passphrase only the owner knows.

## 1. Operator key (daily use, stays on the workstation, passphrase-protected)

```sh
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
mise exec -- age-keygen | mise exec -- age -p -a -o ~/.config/sops/age/operator.age
```

- `age-keygen` prints one line starting `Public key: age1...`. Copy that line.
- `age -p` asks twice for a passphrase. Use a long one: six or more random words. It is the only thing between a stolen laptop and every secret.
- The private key goes straight from one program into the other. Only the encrypted file reaches the disk.

## 2. Recovery key (offline, never on the workstation)

```sh
mise exec -- age-keygen
```

- It prints three lines. Store all three in the password manager as "homelab age recovery key", and write them on the two paper copies.
- Copy the `# public key: age1...` value.
- Then clear the terminal: `clear && history -c`.

The recovery key is used only from an offline or live-USB environment, in drills and in a real recovery.

## 3. Hand over the two public keys

Public keys are not secret. They go into `private/.sops.yaml` as the recipients of every file. Add them through a pull request, or give them to whoever maintains the repository.

## 4. Use

A session loads the operator key on demand and never stores it decrypted:

```sh
export SOPS_AGE_KEY_CMD='age -d ~/.config/sops/age/operator.age'
sops private/<file>.sops.yaml      # asks for the passphrase
```

## Verification (Phase 1 gate)

1. `sops` can create and reopen a test file in `private/` with the operator key.
2. The same file decrypts with the recovery key alone, typed from the paper copy, on a machine that is offline.
3. `grep -r "AGE-SECRET-KEY" ~ 2>/dev/null` finds nothing on the workstation.

## Rotation and loss

| Event | Action |
|---|---|
| Yearly, or the laptop is replaced | New operator key; update `.sops.yaml`; `sops updatekeys -y` on every file |
| Laptop stolen, or the passphrase may be known | Treat every secret as disclosed: `operator-key-compromised.md` |
| Recovery key exposed | New recovery key; `sops updatekeys -y`; replace both paper copies |
