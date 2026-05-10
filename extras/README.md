# Extras

Optional add-ons that build on the same patterns as the main backup
chain but address narrower gaps. Each script is self-contained and can
be adopted independently.

## Contents

| Script                              | Addresses                                                   |
|-------------------------------------|-------------------------------------------------------------|
| `security-onion-config-backup.sh`   | Security Onion is too large for a full PBS backup, but its configuration IS worth preserving. This captures only the configuration surface (~40 KB archive) so the SO instance can be rebuilt after a clean reinstall. Tested on SO 3.0.0 / Oracle Linux 9.7. |
| `rpi-image-luks-wrapper.sh`         | Wraps the RPi image storage on mx-secondary in a LUKS volume using the same key-custody pattern as the rest of the chain (eval "$KEY_CMD" \| cryptsetup --key-file /dev/stdin), with init / open / close subcommands. Tested on Ubuntu 24.04 LTS (OVH dedicated).. |

## Status

These are **proposed** for the production setup, not yet deployed at the
time of writing — they are part of the roadmap, ready to ship. The main
chain (orchestrator + per-node scripts + verification) has been running
for years; these two scripts close two specific gaps the threat model
flagged.

## security-onion-config-backup.sh — detail

### What is captured

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

- The `pillar.items` dump in `_state/` routinely contains credentials and
  internal addresses. Review before treating the archive as portable or
  transferring it offsite.
- The output archive is mode `0600`. Ship it inside a LUKS volume like
  every other offsite artefact in this chain — do not assume "no PCAPs"
  means "no sensitive data".

## rpi-image-luks-wrapper.sh — hardening notes

- LUKS overhead on Pi-class CPUs is the bottleneck. Benchmark with
  `cryptsetup benchmark` on the target node before sizing.
- The init step is non-interactive — the key is piped from --key-cmd
  directly into cryptsetup luksFormat --key-file /dev/stdin --batch-mode. 
  A recovery passphrase can be added afterwards with cryptsetup luksAddKey
  in case the key holder (nas-core) is unavailable during an emergency restore.