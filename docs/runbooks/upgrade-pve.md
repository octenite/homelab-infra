# Runbook: upgrade the Proxmox VE host

Use this in the monthly maintenance window. Proxmox packages are not upgraded unattended. Only Debian security updates install themselves.

## Before

Needed: the workstation on one of its two addresses, the repository in WSL, the backup server VM running.

1. Open a session.

   ```sh
   just session-start
   ```

2. Confirm the host matches Git. The run must end without a failure and with `changed=0`.

   ```sh
   just pve-apply
   ```

3. Confirm a host-configuration backup from the previous night exists. Guest backups join this check in Phase 5.

   ```sh
   export SSH_AUTH_SOCK="$HOME/.ssh/homelab-agent.sock"
   ssh ops@10.0.10.10 sudo pbs-host-restore list
   ```

   The newest snapshot carries last night's date.

4. Read the release notes of the versions about to be installed.

## Upgrade

1. Log in and list what would change.

   ```sh
   ssh ops@10.0.10.10
   sudo apt update
   apt list --upgradable
   ```

2. Upgrade.

   ```sh
   sudo apt full-upgrade
   ```

3. Reboot only if a kernel or firmware package was installed.

   ```sh
   sudo reboot
   ```

   Guests stop during the reboot. Until the cluster exists, nothing else is affected.

## After

1. The expected versions are installed.

   ```sh
   ssh ops@10.0.10.10 pveversion -v
   ```

2. The host firewall is enabled and running.

   ```sh
   ssh ops@10.0.10.10 sudo pve-firewall status
   ```

3. The host still matches Git: no failure, `changed=0`. This run also asserts that the nightly backup timer is armed.

   ```sh
   just pve-apply
   ```

4. Record the versions in the gate record of the current phase.
5. Close the session.

   ```sh
   just session-end
   ```

The upgrade worked when steps 1 to 3 pass.

## If something breaks

The previous kernel stays installed and can be chosen at boot on the console. The host is reproducible: [proxmox.md](../components/proxmox.md), Restore.
