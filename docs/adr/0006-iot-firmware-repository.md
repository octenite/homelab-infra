# ADR-0006: The IoT device firmware lives in a private companion repository

- Status: Proposed on 2026-10-27, built the same day; the owner's merge of the pull request that adds the submodule is the acceptance
- Date: 2026-10-27
- Deciders: repository owner
- Supersedes: none. It extends decision 27 of `../ARCHITECTURE.md` section 19 (one public repository plus a private submodule) to a second private submodule

## Context

Two ESP32 boards built with the ESPHome Device Builder are online: one replaces the room's switch board, one switches the mains supply of the workstation's desk. Three or four more are planned (household plan, H1). Their configuration existed only inside the builder, which breaks the rules of `CLAUDE.md`: not reproducible from Git, no review, no pinned builder version, secrets typed by hand into a tool that stores them in the clear.

On 2026-10-23 the owner asked whether that configuration belongs in this repository or in one of its own, and on 2026-10-27 asked for it to be built as a private module that the IDE and the agents see together with this repository.

Facts that bound the choice:

1. **Firmware has its own lifecycle and toolchain.** A device build is minutes of ESP-IDF compilation with a toolchain cache of about a gigabyte. Nothing in it resembles the YAML, OpenTofu and Ansible checks of this repository. Deployment is a flash over the air from the workstation, not a reconciliation by Argo CD.
2. **The device files are identifiers.** They name the IoT network, the addresses, the device hostnames and the wiring of the house. The public-tree policy forbids exactly that here, and the ESPHome secrets (network key, API keys, OTA and web passwords) are ciphertext, which this repository refuses by rule.
3. **Two boards switch mains voltage.** A pin or a restore mode on them is a safety matter and deserves its own review surface and its own document.
4. **One operator, one checkout.** Whatever is built must appear inside the one working tree the owner and the agents use, with no per-tool configuration.

## Decision drivers

- The same custody rules as the private repository: SOPS with the two existing age keys, no plaintext secret on the unencrypted workstation disk (X23), no key in CI.
- One tree in the IDE and for every agent, without workspace files or extra directories to declare.
- The public repository stays public and learns nothing new about the devices beyond what it already records (addresses and firewall exceptions).
- The same engineering standards: pinned tools, Renovate, pre-commit, CI on every pull request, a document per component.

## Decision

**A second private repository, `homelab-iot`, mounted as the Git submodule `iot/` and pinned by commit, exactly like `private/`.**

| | `private/` | `iot/` |
|---|---|---|
| Holds | ciphertext and the identifying inventory | ESPHome device files, shared packages, its own `secrets.sops.yaml` and the CI dummies `secrets.ci.yaml`, a document per device |
| SOPS recipients | operator and recovery keys | the same two keys, in its own `.sops.yaml` |
| Reading and writing a value | `just reveal`, `just secret-set` | the same recipes, which accept an `iot/` path |
| CI | encrypted-files guard, Gitleaks | the same guard plus a plaintext-credential check, yamllint, shellcheck, actionlint, Gitleaks, `esphome config` and `esphome compile` of every device with the dummy secrets |
| Checked by | `just private-status` | `just private-status` (both, by default) |
| Excluded from | the public CI checkout, the policy test, the scanners, yamllint | the same, plus the public working-tree Gitleaks scan, because the firmware repository carries its own allowlist |

Design points, each with its reason:

- **Device files at the top level, packages in `packages/`.** The layout the Device Builder expects, so a builder container can later mount the repository as its configuration directory without a change.
- **`secrets.yaml` is never a file on disk.** ESPHome reads `secrets.yaml` beside the device files. Here it is always a symbolic link: to `secrets.ci.yaml` (dummy values, enough to validate and compile), or, after `just unlock`, to a decrypted copy in the session's memory directory, which the session's end removes. The guard refuses the file in any other form. Reason: X23.
- **CI holds no key.** The compile runs against the committed dummy values, which the guard constrains to an obvious shape. CI proves that a configuration builds with the pinned ESPHome; the flash from the workstation proves the rest.
- **The flash is `esphome run`**, which validates, compiles with the unlocked secrets and uploads in one step, so an upload can never send a binary compiled from the dummies. The wrapper refuses the dummies and placeholder values outright.
- **Addresses come from the router's reservations**, not from static addresses in the firmware. The device file carries the address only as `use_address`, so the esphome tool finds the device across the network boundary (names do not cross from the trusted to the IoT network).
- **Every device carries the login on its web page and no firmware upload through the page** (backlog B35), an encrypted native API and encrypted updates over the air with the device's key. The migration from the hand-built firmware's OTA password is one documented flash per device.
- **The ESPHome version is pinned in `mise.toml`** and bumped by Renovate as a reviewed pull request, never automerged, because a bump changes every firmware and every device is flashed afterwards.
- **Hardware is never guessed.** The device files hold the shared packages and the network identity; the owner pastes the hardware section from the builder's export, with a restore mode on every switch, and fills the pin map in the device's document (B53). Until then the files build a firmware that must not be flashed, and the wrapper's refusals plus the documents say so.

## Alternatives considered

| Alternative | Why not |
|---|---|
| The device files inside this public repository | Every file is an identifier by the public-tree rule, the secrets would be ciphertext in a public history, and the firmware compile would sit in a CI pipeline built for manifests. The owner's question of 2026-10-23 was answered the same way |
| Inside `homelab-private` | That repository holds ciphertext and inventory under a guard that knows nothing of firmware, and its CI must stay small. Mixing a compile pipeline into it blurs what each repository is for |
| A sibling checkout plus a multi-root workspace and per-agent directory declarations | Works, but is configuration every machine and every tool repeats, and the link between the repositories lives nowhere in Git. The submodule carries it, and the rebuild runbooks rely on that |
| Keep the Device Builder as the source of truth and export to Git | The builder is a tool with a database, not a reviewed history; its secrets are plain text on whatever host runs it. Git is the source; a builder may later read from the repository |
| Static addresses in the firmware | Two sources of truth for one address. The reservation already exists for the first device and the design keeps it as the one place |

## Consequences

- Every device change is two commits: one in `iot/`, one in this repository to move the pin. `just private-status` reports a lagging pin as a note, not a fault.
- The IoT Wi-Fi key now exists in two SOPS files. Procedure R2 of the secrets register updates both and flashes every device.
- Nothing in the lab depends on the firmware repository being reachable: the devices run what they were flashed with.
- The CI minutes of a private repository on GitHub Free are limited. The compile job caches the toolchain per ESPHome version and the build per device, and runs only on pull requests and pushes to `main`.
- The migration flash and the hardware sections are owner work (B52, B53). Until then the repository proves the pipeline and nothing has changed on either board.
- A later ESPHome builder or Home Assistant on the platform (B5) reads this repository; its secrets would then need the same unlock on that host, which is designed when B5 is built.
