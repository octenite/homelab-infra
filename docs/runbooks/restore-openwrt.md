# Runbook: restore the router or an access point

Use this when a device is misconfigured beyond a normal apply, was reset, or was replaced.

## Decide which path

| Situation | Path |
|---|---|
| The device is reachable over SSH and only its managed configuration is wrong | A: apply from Git |
| The device is reachable, but something outside the managed files is wrong | B: restore the backup archive |
| The device is unreachable | C: failsafe, then B |
| The device was replaced or factory-reset | D: first contact, then A |

Always work from the wired workstation with a session open (`just session-start`).

## A. Apply from Git

```sh
just openwrt-check <host>     # shows what differs
just openwrt-apply <host>     # applies with the automatic revert
```

## B. Restore the backup archive

The archives are in the private repository under `openwrt/backups/<date>/`. Verify the one you pick against `SHA256SUMS` first.

```sh
cd private/openwrt/backups/<date>
sops decrypt --output-type binary <device>.sysupgrade.sops.json | sha256sum      # compare with SHA256SUMS
sops decrypt --output-type binary <device>.sysupgrade.sops.json \
  | ssh root@<address> 'cat > /tmp/backup.tar.gz && sysupgrade -r /tmp/backup.tar.gz && reboot'
```

The archive only ever exists in the device's memory. Afterwards run path A, because the backup predates later changes in Git.

## C. Failsafe mode

1. Power the device on and press the reset button repeatedly while the status light blinks fast.
2. Give the workstation the address 192.168.1.2/24 on the wired port. The device answers on 192.168.1.1 with no password.
3. `ssh root@192.168.1.1`, then `mount_root`.
4. Continue with path B, using 192.168.1.1 as the address.

If the router does not boot at all, it has a second firmware slot and a D-Link recovery page; see the device page on the OpenWrt wiki. The recovery page needs a Chromium-based browser.

## D. First contact with a new or reset device

1. Flash the OpenWrt release recorded in the private inventory. For the router, keep the matching recovery image.
2. From the wired port, install the two authorised keys by hand once: the public keys are in the private inventory, `group_vars/openwrt/ssh.yaml`.
3. Set the device's address so the inventory can reach it, then run path A.
4. For the router, confirm the internet link first: the static WAN address, gateway and cloned MAC address come from the private inventory.

## Afterwards

- `just openwrt-check openwrt` reports no differences.
- Record the event and its cause in the gate record of the current phase.
