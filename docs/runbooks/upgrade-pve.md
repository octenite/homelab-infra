# Runbook: upgrade the Proxmox VE host

Proxmox packages are not upgraded unattended. Only Debian security updates install themselves. Everything else happens in the monthly maintenance window, by hand, with this runbook.

## Before

1. A verified backup of the control-plane VM and the host configuration from the previous night exists (Phase 3.5 onwards).
2. The session is open and `ansible-playbook playbooks/pve.yaml` reports no changes.
3. Read the release notes of the versions about to be installed.

## Upgrade

```sh
ssh ops@10.0.10.10
sudo apt update
sudo apt list --upgradable
sudo apt full-upgrade
```

Reboot only if a kernel or firmware package was installed:

```sh
sudo reboot
```

Guests stop during the reboot. Until the cluster exists, nothing else is affected.

## After

1. `pveversion -v` shows the expected versions.
2. `ansible-playbook playbooks/pve.yaml` reports no changes.
3. The host firewall is enabled: `sudo pve-firewall status`.
4. Record the versions in the maintenance log of the current phase.

## If something breaks

The previous kernel stays installed and can be chosen at boot on the console. The host is reproducible: `docs/components/proxmox.md`, Restore.
