# Architecture

This document describes the topology of the backup covered by this
repository. The hosts involved, what they do, and how data flows
between them. The wider security architecture (WAF, NGFW, NSM, XDR)
is explained in another repository
[`Lionel-Rousseau/laflanelle-secops-architecture`](https://github.com/Lionel-Rousseau/laflanelle-secops-architecture).

## Hosts

| Host                          | Role                                | OS / Platform        | SSH port | Where        |
|-------------------------------|-------------------------------------|----------------------|----------|--------------|
| `orchestrator.example.net`    | Backup conductor (this repo)        | Debian VM (Proxmox)  | 22       | LAN - Site A |
| `nas-core.example.net`        | Aggregating NAS, USB rotation       | Synology DSM 7.3.x   | 1249     | LAN - Site A |
| `web-mail.example.org`        | Web + primary MX (Internet-facing)  | Ubuntu 24.04 LTS     | 1622     | OVH - DC1    |
| `mx-secondary.example.org`    | Secondary MX + offsite storage      | Ubuntu 24.04 LTS     | 1622     | OVH - DC2    |
| `rpi-*.example.net`           | IoT automation Pi nodes             | Raspberry Pi OS      | 22       | LAN - Site A |

The orchestrator is the only host that initiates SSH connections during
the nightly run; every other host listens. SSH ports are non-default
(1249 / 1622) as a low-effort mitigation against opportunistic scanning (also as part of historic ports in the infrastructure - NAT),
naturally not used as a primary defense. The main defense is based on key-only authentication,
disabled root password, and `fail2ban` watching `auth.log`. DC stands
for Data Center, each one is located in France and at different locations.
OVH dedicated servers run software RAID 1 (example : 2 × 4 TB → ~4 TB usable) at the hardware 
layer. RAID provides resilience against single-disk failure; it is not a substitute 
for the cross-site backup chain described in this document.

## Data flow (nightly)

```
                           orchestrator.example.net
                                    │
            ┌───────────────────────┼────────────────────────┐
            │                       │                        │
            ▼                       ▼                        ▼
  nas-core.example.net    web-mail.example.org      mx-secondary.example.org
       (Synology)          (Ubuntu, OVH DC1)          (Ubuntu, OVH DC2)
            │                       │                        │
            │       ┌───────────────┼─────────────┐          │
            │       │               │             │          │
            └──────►│         (rsync over         │◄─────────┘
                    │          SSH, LUKS          │
                    │       on remote side)       │
                    │                             │
                    └─────────────────────────────┘
                              cross-site

            ┌─────────────────────────────────────────────┐
            │  USB drive (rotated weekly, off-site copy)  │
            └─────────────────────────────────────────────┘
                            ▲
                            │  daily mirror
                            │
                  nas-core.example.net
```

## Encryption posture

| Link / At-rest                                    | Confidentiality                          |
|---------------------------------------------------|------------------------------------------|
| `nas-core` ←→ everything else (LAN side)          | SSH transport. **Cleartext at rest** on the NAS by design - the NAS is the read-fast aggregation point and the LAN is trusted. |
| `web-mail` ←→ `mx-secondary` (cross-OVH)          | SSH transport + **LUKS at rest** on both ends |
| `web-mail` / `mx-secondary` → `nas-core` (LAN)    | SSH transport, cleartext at rest on the NAS |
| Mail spool (`vmail`) → `nas-core`                 | SSH transport, decrypted at the source from a local LUKS volume, cleartext at rest on the NAS |
| RPi root image → `mx-secondary` → `nas-core`      | SSH transport (sshfs), **cleartext at rest** - known gap, see [`extras/rpi-image-luks-wrapper.sh`](../extras/rpi-image-luks-wrapper.sh) |
| USB storage drive                                 | Cleartext on disk. The drive is physically attached to the NAS inside a locked IT enclosure. |

The asymmetry is deliberate: the LAN side trades confidentiality for fast
random read access (so we can `grep` through old mail or restore a
single file without unlocking a container), while the WAN side never
leaves a decrypted volume mounted longer than the time it takes to
write a delta.

## LUKS key custody

LUKS keys for the offsite containers are not stored on the host that
mounts them. They are read just-in-time by piping
`ssh nas-core 'cat /volume1/NetBackup/.ash'` into `cryptsetup open
--key-file /dev/stdin`, which means:

- a compromise of `web-mail` alone does not expose the key
- a compromise of `mx-secondary` alone does not expose the key
- a compromise of `nas-core` exposes the key, but `nas-core` already
  holds the cleartext aggregation, so this does not lower the bar
- a network attacker cannot intercept the key without already having the
  SSH private key

The key file (`.ash`) on `nas-core` is mode `0400`, owned by `root`. Its confidentiality relies on access control at the OS level. A compromise of the NAS with root privileges would expose it.

## Adjacent layer - Proxmox VMs

Not driven by this repository, but worth documenting because it is part
of the same backup posture: the Proxmox Server runs critical service VMs
(NGFW on OPNsense / FreeBSD, Unbound DNS / FreeRADIUS on Debian, Wazuh /
Git / monitoring on the orchestrator host, Zabbix on Rocky Linux), all
backed up nightly by **Proxmox Backup Server** with two snapshot
generations retained. PBS handles both deduplication and integrity
verification on its own. Restoration tests run on a dedicated test
Proxmox node twice a month.

Security Onion is the one VM not covered by PBS due to its size; a
narrower script that snapshots only its rules and tuning configuration
ships in [`extras/security-onion-config-backup.sh`](../extras/security-onion-config-backup.sh).
