# Runbook: create the operator and recovery keys

Purpose: create the two age identities that every SOPS file is encrypted to, without a private key ever being written to disk in readable form. The workstation's disks are not encrypted (exception X23), so this matters.

Who: the owner, once, in a WSL terminal inside the repository. Nobody else can do this step, because it needs a passphrase only the owner knows.

## 0. Before you start

The pinned tools are provided by mise, per repository. Two things must be true, or the shell answers `mise: command not found` or `age-keygen: command not found`:

1. **Use a terminal opened after mise was installed.** `~/.bashrc` activates mise, and a terminal that was already open does not see it. Open a new WSL tab, or run `source ~/.bashrc` in the old one. Keep the terminal that holds the SSH agent open.
2. **Be inside the repository.** The tools are only on the path there.

```sh
cd /mnt/d/Dev/homelab-infra
age --version        # must print v1.x; if not, see the two points above
```

If `~/.bashrc` has no mise line (a new machine), add these two and reopen the terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash)"
```

## 1. Operator key (daily use, stays on the workstation, passphrase-protected)

```sh
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
age-keygen | age -p -a -o ~/.config/sops/age/operator.age
```

- `age-keygen` prints one line starting `Public key: age1...`. Copy that line. It appears on the same line as the passphrase prompt, which looks odd and is harmless.
- `age -p` asks twice for a passphrase. Type your own: six or more random words. It is the only thing between a stolen laptop and every secret. If you leave it empty, age invents one and prints it once; write it down before doing anything else.
- Afterwards: `chmod 600 ~/.config/sops/age/operator.age`.
- The private key goes straight from one program into the other. Only the encrypted file reaches the disk.

## 2. Recovery key (offline, never on the workstation)

```sh
age-keygen
```

- It prints three lines. Store all three in the password manager as "homelab age recovery key", and write them on the two paper copies.
- Copy the `# public key: age1...` value.
- Then clear the terminal: `clear && history -c`.

The recovery key is used only from an offline or live-USB environment, in drills and in a real recovery.

## 3. Hand over the two public keys

Public keys are not secret. They go into `private/.sops.yaml` as the recipients of every file. Add them through a pull request, or give them to whoever maintains the repository.

## 4. Use

The operator key is decrypted into the memory of one command and never stored:

```sh
SOPS_AGE_KEY="$(age -d ~/.config/sops/age/operator.age)" sops edit private/<file>.sops.yaml
```

`age -d` asks for the passphrase. The decrypted key exists only in that one `sops` process. Do not `export` it, and do not redirect it to a file on a disk.

For longer work, such as an Ansible run that reads the encrypted inventory, open a session instead:

```sh
just session-start     # asks for the SSH key passphrase and the age passphrase
just openwrt-check     # or any other recipe that needs secrets
just session-end       # removes the decrypted key
```

The session keeps the decrypted key in `/dev/shm`, which is memory, not disk. It disappears on `just session-end`, when WSL stops, or when the laptop powers off. Always close the session when the work is done.

## Verification (Phase 1 gate)

1. **Operator key.** In a WSL terminal inside the repository:

   ```sh
   SOPS_AGE_KEY="$(age -d ~/.config/sops/age/operator.age)" sops decrypt private/selftest/selftest.sops.yaml
   ```

   It must print two lines, `purpose:` and `canary:`. This proves the passphrase is known and the key file is intact.

2. **Recovery key alone, offline.** On a machine with networking off (a live USB is ideal), with `age` and `sops` available and a copy of `selftest.sops.yaml`:

   ```sh
   read -rs SOPS_AGE_KEY && export SOPS_AGE_KEY     # type the AGE-SECRET-KEY line from the paper copy
   sops decrypt selftest.sops.yaml
   ```

   It must print the same two lines. This proves that the paper copy is correct and sufficient. Do it before the first real secret is stored: a recovery key that was written down wrongly is worthless, and it is only discovered when it is needed.

3. **Nothing readable on the workstation.** `grep -rIl "AGE-SECRET-KEY-" ~ 2>/dev/null` finds nothing.

## Rotation and loss

| Event | Action |
|---|---|
| Yearly, or the laptop is replaced | New operator key; update `.sops.yaml`; `sops updatekeys -y` on every file |
| Laptop stolen, or the passphrase may be known | Treat every secret as disclosed: `operator-key-compromised.md` |
| Recovery key exposed | New recovery key; `sops updatekeys -y`; replace both paper copies |
