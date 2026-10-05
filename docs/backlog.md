# Backlog

Open items that are not part of the phase currently in progress. Each has an owner and the point at which it is picked up. Items leave this list when a gate record or a pull request closes them.

| # | Item | Detail | Owner | When |
|---|---|---|---|---|
| B1 | Radio settings in the public history | One file in one commit of the public repository (the squash commit of pull request 6) shows the router's radio settings as they were on 2026-10-05: regulatory country code, channel, channel width and transmit power for both bands. Nothing else of that kind is in the history: a scan of every commit found no network name, key, MAC address or WAN address. The current tree keeps those settings in the private repository. Removing the old commit means rewriting the public history, and the pull request page would still show it unless the repository is deleted and recreated or GitHub support purges it | Owner decides | Parked by the owner on 2026-10-05 |
| B2 | Main Wi-Fi network uses WPA2 and WPA3 together | If an older device cannot join, the network is switched to WPA2 only | Owner reports | As it occurs |
| B3 | Metrics exporter on the router and access points | Deferred from Phase 2: nothing can scrape it yet. Arrives with firewall rule E7 | Operator | Phase 9 |
| B4 | Move the ESP32 to the IoT network | It runs ESPHome and is driven by HTTP shortcuts on the phone. Add the IoT network to its Wi-Fi configuration and flash over the air while it is still on the old network. Its fixed address in the IoT network is 10.0.60.10, so the shortcuts need one edit. The IoT network covers the whole house since Phase 4 | Owner | Any time |
| B5 | Home Assistant | First named application. Needs a firewall exception from its address in the servers network to the IoT network (the ESPHome API), recorded as a new exception. Devices are addressed by fixed address, so no discovery reflector is needed | Operator | Phase 14 |
| B6 | GitHub token at rest | Replace the token stored by the GitHub CLI with a fine-grained token limited to the two repositories, with an expiry (gap against exception X23) | Owner | Owner's timing |
| B7 | `mise.lock` and the repository setting that requires actions pinned by SHA | Tooling hardening left from Phase 1 | Operator | With the first Renovate pull request |
| B8 | Hardware security keys | Two FIDO2 keys for the password manager and GitHub | Owner | Owner's timing |
| B9 | Direct 2.5 GbE cable shows no link | At both ends. Check the cable and both ports | Owner | Before Phase 3 |
| B10 | Synchronous-write benchmark of the Node 1 SSD | Decides whether the SSD is replaced before the cluster is built | Operator | Phase 3 gate |
| B11 | UPS battery sensor | ESP32 measuring the battery bank's voltage, feeding an orderly shutdown | Owner and operator | After Phase 4 |
| B12 | Narrow IoT access to the internet | Exception E8 allows everything today (X11) | Operator | When the device list is known |
| B13 | Unused mail records in the lab DNS zone | Deleting them removes exception X24 | Owner | Owner's timing |
| B14 | Node 2 facts | Existing Hyper-V VMs, hours it is reliably on, Windows update channel, a week of memory measurements | Owner | Before the backup server VM is sized in Phase 3 |
| B15 | Application wishlist | Home Assistant is named. Everything else is open, and it decides the resource budget | Owner | Before Phase 14 |
| B17 | Printer placement | The printer is on the old network name, which becomes the guest network. Guests are isolated, so it cannot stay there and be printed to. Recommended: join it to the IoT network and give it a fixed address; computers and phones on the main network can already open connections to it. Printing by address then works. Automatic discovery from phones (AirPrint, Mopria) does not cross networks without a small discovery reflector on the router between the main and IoT networks, which is added if phones need to print. The simpler alternative is the main network, at the price of an unpatched device among the trusted ones | Owner decides | Before the guest switch |
| B18 | Guest switch | Old network name to the guest network with client isolation, on all three devices in one run; then the guest and roaming tests | Operator | When the owner has moved the trusted devices |
| B16 | Second WAN configuration on the router | The multi-WAN package and its configuration are present but the second link is disabled. Either bring it under Ansible or remove it | Owner decides | Phase 4 or later |
