# Runbook: build or rebuild the administration container remote1

Use this when the container `remote1` (guest 3010 on pve1) has to be created: the first time, after a new template pin, a changed key list, a broken container, or a rebuilt hypervisor. At home only, on the wired workstation, with a session open. The container holds no data (decision D9 of `docs/phases/phase-r-plan.md`).

Status: written with step R.7 on 2026-10-12. The deletion in section 3 and the recovery section are not rehearsed yet.

Why a runbook and not a plan: the container is protected against deletion, and OpenTofu's root refuses a destroy or a replacement (`scripts/tofu/child.sh`). A replacement by plan would stop the container first and then be refused by the hypervisor.

Any other change to the root `remote` is applied at home or with the container stopped: a change of memory, name servers, host name or the network device makes the provider reboot a running container, and away from home that container is the path the apply travels on.

## 1. Before creating

1. The hypervisor's own firewall file for the guest must exist before the guest does:

   ```sh
   just pve-apply --check --diff
   just pve-apply
   ```

   The play writes `/etc/pve/firewall/3010.fw`, fetches the template and compares it with its pin. Proxmox parses a guest's firewall file only once the guest exists, so the play's compile check proves this file from its second run on; `just test-remote` proves it before the first start.
2. The token's scope and the refusals that the build relies on:

   ```sh
   just test-token
   ```

3. Only when the template pin is new: does the template run without the nesting feature?

   ```sh
   just nesting-probe
   ```

   It creates a throwaway container (guest 9909), reads systemd's state inside it and destroys it. `nesting` in `infrastructure/opentofu/roots/remote/main.tf` can be set at creation only; a `true` there is a deviation from decision D2 and needs the owner's word.

## 2. Create

1. Plan and apply. The wrapper compares the template on the hypervisor with the pin before and after, refuses when guest id 3010 is taken by something that is not in this root's state, and checks after the apply that the guest's firewall file is still there.

   ```sh
   just tofu remote init
   just tofu remote plan
   just tofu remote apply
   ```

   The container is created stopped. A warning that systemd may need nesting is expected.
2. Start it. The recipe reads back what the hypervisor stored and what its firewall has loaded, refuses to start when one line disagrees, and reads again afterwards:

   ```sh
   just remote-start
   ```

   If it reports that the guest's firewall file is missing, a failed creation removed it: run `just pve-apply`, then the recipe again.
3. Probe from inside, with the hypervisor's filter on and then off:

   ```sh
   just test-remote layers
   just pve-apply
   just test-remote
   ```

   The play puts the firewall file back into the layout Git has, after the test switched the filter off and on through the API. It must report that one file changed, and nothing on a further run. The last command reads the loaded filter once more, after the last write to it.
4. `just tofu remote plan` must show no changes. Commit the private repository: the state copy of the root `remote`.

Then the inside of the container (step R.8; `docs/components/remote1.md`):

```sh
just remote-bootstrap      # once, as root: answer "yes" to the one host-key question
just remote-apply          # the role; a second run must change nothing
just remote-login          # the owner: a browser login, then the signing command for the laptop
just secret-set private/ansible/inventory/host_vars/remote1/secrets.sops.yaml remote_ct_health_ping_url
                           # the dead-man's switch, after the signature (the timer reports failure before it)
just remote-apply          # after the signature: the remaining preferences set once, the health timer installed
just remote-apply          # must change nothing
just test-remote layers    # the probes with each layer off in turn, then just pve-apply and just test-remote
```

Then one reboot (`ssh ops@10.0.10.10 sudo pct reboot 3010`) and `just test-remote` once more: the filter, the masked units, the kernel settings and the SSH listener must come back by themselves. When the container is stopped on purpose (decision D12), pause the check in the healthchecks.io console until `travel.ps1` (step R.9) does it.

After a rebuild the container has a new SSH host key: `ssh-keygen -R remote1` on the workstation first, and the old device removed in the Tailscale console (**Machines**) before the login, or the new one is named `remote1-1`.

## 3. Remove the old container first (a rebuild only)

1. Remove the device `remote1` in the Tailscale console (**Machines**): its key does not expire by itself.
2. Switch the protection off on the hypervisor. The guest leaves the state in step 4, so OpenTofu is not involved and `main.tf` keeps `protection = true` for the new container:

   ```sh
   ssh ops@10.0.10.10 sudo pct set 3010 --protection 0
   ```

3. Stop it if it runs, then delete it:

   ```sh
   ssh ops@10.0.10.10 'sudo pct status 3010 | grep -q running && sudo pct stop 3010; sudo pct destroy 3010'
   ```

   The hypervisor removes the guest's firewall file and its pool membership with it.
4. Take the guest out of the state, if it is there. Without this every later plan fails with "HTTP 403": the token's right to read the guest came from its pool membership, and the provider does not read a 403 as "gone".

   ```sh
   just tofu remote state list
   just tofu remote state rm module.remote1.proxmox_virtual_environment_container.this
   ```

5. Go on with sections 1 and 2. With a new template pin, section 1 comes first in any case: the wrapper refuses a plan while the newly pinned file is not on the hypervisor. The new container gets the template and the keys that Git names now, and a new SSH host key: remove the old one with `ssh-keygen -R remote1` before the first login.

## The guest exists and the state does not hold it

This happens when a creation ran longer than the provider waited, when its last read failed, or when the state was lost. `just tofu remote plan` then answers `guest id 3010 is taken`, or `Instance cannot be destroyed`.

1. `just tofu remote state list`. If the address is listed, the creation was recorded as failed: `just tofu remote untaint module.remote1.proxmox_virtual_environment_container.this`, then plan. Stop here if the plan is clean.
2. Otherwise confirm that the guest is remote1: `ssh ops@10.0.10.10 sudo pct config 3010` (host name, pool, net0). An import does not help: the provider cannot read the pool, so the plan after it asks for a replacement.
3. Remove it and build again: section 3 from step 2, then sections 1 and 2.

## How to know it worked

- `just tofu remote plan` shows no changes, with the container stopped and with it running.
- `just test-remote layers` ends with `remote1 as designed`, and so does a plain `just test-remote` after the last `just pve-apply`.
- `just pve-apply` reports no change on its second run.

## If something fails

| Symptom | Cause and action |
|---|---|
| `guest id 3010 is taken ... Nothing was planned` | A guest holds the id and this root's state does not know it, or the state could not be read. See "The guest exists and the state does not hold it". Never plan onto it |
| `template ... is not the pinned one`, or `is missing` | The file on the hypervisor differs from the pin, or a newly pinned file was not fetched yet. Run `just pve-apply`, which fetches it and names a difference. Do not create a container until it passes |
| `the template differs from its pin after the apply` | Treat a container created by that apply as not trustworthy: remove it with section 3 and build again |
| `the template could not be checked after the apply` | The hypervisor did not answer over SSH. Nothing says the template changed. Run `bash scripts/tofu/template-pin.sh` before the container is started |
| `the hypervisor's firewall file for guest 3010 is missing or switched off` | A creation that failed half-way removed it, or something switched it off. `just pve-apply`, then `just test-remote`, before any start |
| The apply stops with a permission error on creation | Read the path and the privilege in the message and compare with `just test-token`. The token may set no tags and no feature other than nesting |
| A plan fails with "HTTP 403" on the guest's configuration | The guest was deleted outside OpenTofu: section 3, step 4 |
| `just test-remote`: no SSH login to the container | The container is stopped, or the hypervisor's filter or the router refuses the workstation: `just test-router-zones`, then the first part of `just test-remote`, which needs no login |
| `just test-remote layers` died while the filter was off | The hypervisor switches it on again by itself within ten minutes (`systemctl list-timers 'homelab-fw*'` on pve1). `just pve-apply` does it at once |
