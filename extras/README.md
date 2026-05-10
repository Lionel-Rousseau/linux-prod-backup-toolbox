# Extras

Optional add-ons build on the same patterns as the main backup
chain but address some gaps. Each script is self-contained and can
be called independently.

## Contents

| Script                              | Addresses                                                   |
|-------------------------------------|-------------------------------------------------------------|
| `security-onion-config-backup.sh`   | Security Onion is too large for a full PBS backup, but it is important to keep its configuration. This captures only the configuration surface (~40 KB archive) so the SO instance can be rebuilt after a clean reinstall. Tested on SO 3.0.0 / Oracle Linux 9.7. |
| `rpi-image-luks-wrapper.sh`         | Wraps the RPi image storage on mx-secondary in a LUKS volume using a key stored in a file (locally or remotely by ssh), with init / open / close subcommands. Tested on Ubuntu 24.04 LTS (OVH dedicated). |

## Status

These are **proposed** for the production setup, not yet deployed at the
time of writing but almost ready. The main chain (orchestrator + per-node scripts
verification) has been running for a long time and these two scripts close two
specific gaps brought by the recent introduction of the Rpi imaging option.

## security-onion-config-backup.sh

### The files selection

| Path | Content |
|---|---|
| `/opt/so/saltstack/local/pillar/` | Your SO settings — the only input Salt needs to reconfigure all services on reinstall |
| `/etc/salt/` | Salt master config |
| `/etc/yum.repos.d/securityonion.repo` | Exact version reference for reinstall |
| `/opt/so/rules/suricata/local.rules` | Custom Suricata rules (empty on a fresh install; add more paths here as needed) |
| `_state/` | Runtime snapshot: `so-status`, Docker image list, Salt pillar dump |

### Reinstall procedure (standalone node)

1. Reinstall SO 3.0.x from the ISO — do not run the setup wizard yet.
2. Restore the pillar before the first checkin:
   ```bash
   cp -a /path/to/restore/opt/so/saltstack/local/pillar/ \
         /opt/so/saltstack/local/pillar/
   ```
3. Run `so-checkin` — Salt reads the pillar and reconfigures all containers.
4. Verify with `so-status` that all expected containers are running.

Elastic indices, PCAPs, and Suricata community rules are not backed up —
they regenerate automatically from live traffic and `so-checkin`.

### Hardening notes

- The `pillar.items` dump in `_state/` may contains credentials and
  internal addresses. Review before treating the archive or transferring it offsite.
- The output archive is mode `0600`. Consider putting it inside a LUKS volume to secure it.

## rpi-image-luks-wrapper.sh — hardening notes

- The init step is non-interactive as the key is piped from --key-cmd
  directly into cryptsetup luksFormat --key-file /dev/stdin --batch-mode. 
  A recovery passphrase can be added afterwards with cryptsetup luksAddKey
  in case the key holder (nas-core) is unavailable during an emergency restore.
