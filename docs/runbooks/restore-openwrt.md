# Runbook: restore the router or an access point

Use this when a device is misconfigured beyond a normal apply, was reset, or was replaced.

## Before starting

- Work from the workstation on its wired port, never over Wi-Fi.
- The repository in WSL, with the private repository on `main` (`just private-status`).
- An open session:

  ```sh
  just session-start
  ```

- Commands that are not `just` recipes need the session's key and agent in the shell. Set both once per terminal:

  ```sh
  export SOPS_AGE_KEY_FILE=/dev/shm/homelab-session/age.key
  export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"
  ```

| Device | Inventory name | Address |
|---|---|---|
| Router | `router-m30` | 192.168.1.53 |
| Access point 1 | `ap1` | 10.0.10.2 |
| Access point 2 | `ap2` | 10.0.10.3 |

## Decide which path

| Situation | Path |
|---|---|
| The device is reachable over SSH and only its managed configuration is wrong | A: apply from Git |
| The device is reachable, but something outside the managed files is wrong | B: restore the backup archive |
| The device is unreachable | C: failsafe, then B |
| The device was replaced or factory-reset | D: first contact, then A |

## A. Apply from Git

1. See what differs.

   ```sh
   just openwrt-check <name>
   ```

2. Apply. The device reverts by itself after five minutes unless the change verifies.

   ```sh
   just openwrt-apply <name>
   ```

## B. Restore the backup archive

The archives are in the private repository under `openwrt/backups/<date>/`: per device a `<name>.sysupgrade.sops.json` and a `<name>.uci-export.sops.yaml`, plus `SHA256SUMS`.

1. Go to the backup and verify the archive you picked. The checksum must equal the `<name>.sysupgrade.tar.gz` line in `SHA256SUMS`.

   ```sh
   cd private/openwrt/backups/<date>
   sops decrypt --output-type binary <name>.sysupgrade.sops.json | sha256sum
   grep <name>.sysupgrade SHA256SUMS
   ```

2. Send it to the device and restore. The archive only ever exists in the device's memory.

   ```sh
   sops decrypt --output-type binary <name>.sysupgrade.sops.json \
     | ssh root@<address> 'cat > /tmp/backup.tar.gz && sysupgrade -r /tmp/backup.tar.gz && reboot'
   ```

3. Run path A. The backup predates later changes in Git.

## C. Failsafe mode

1. Power the device on and press the reset button repeatedly while the status light blinks fast.
2. Give the workstation the address 192.168.1.2/24 on the wired port. The device answers on 192.168.1.1 with no password.
3. `ssh root@192.168.1.1`, then `mount_root`.
4. Continue with path B, using 192.168.1.1 as the address.

If the router does not boot at all, it has a second firmware slot and a D-Link recovery page; see the device page on the OpenWrt wiki. The recovery page needs a Chromium-based browser.

## D. First contact with a new or reset device

1. Flash the OpenWrt release recorded in the private inventory. For the router, keep the matching recovery image.
2. From the wired port, install the two authorised keys by hand once, into `/etc/dropbear/authorized_keys` on the device. The public keys are the list `openwrt_ssh_authorized_keys` in `private/ansible/inventory/group_vars/all/ssh.yaml`.
3. Set the device's address so the inventory can reach it (table above).
4. For the router, confirm the internet link first: the static WAN address, gateway and cloned MAC address come from the private inventory.
5. Run path A.

## Afterwards

The restore worked when both of these hold:

1. The devices match Git. The run reports no differences.

   ```sh
   just openwrt-check openwrt
   ```

2. Each device holds the authorised keys of the inventory. For each device the run reports `already as in the inventory`, or `updated and verified by a fresh login`.

   ```sh
   just openwrt-ssh-keys
   ```

Record the event and its cause in the gate record of the current phase. Close the session with `just session-end`.
