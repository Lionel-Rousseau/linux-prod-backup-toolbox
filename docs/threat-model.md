# Threat model

This document is a short statement of what this backup layer is
designed to defend against, and what it is **not** designed to defend against. 
This tells you whether this is sized for your environment.

## Assets

| Asset                          | Why it matters                                           |
|--------------------------------|----------------------------------------------------------|
| Customer database (MySQL)      | Sensitive records for the e-commerce activity. Loss = direct financial impact + accounting / fiscal exposure. |
| Web document root              | Site availability. Loss = revenue interruption until restore. |
| Mail spool (`/home/vmail`)     | Operational continuity (orders, customer support). Loss of older mail is non-fatal but loss of recent days is. |
| OS on web-mail                 | Reproducibility of the public-facing service if the OVH host fails. |
| OS on mx-secondary             | Reproducibility of the secondary MX. |
| Pi root images                 | Convenience an time saving. Re-flashing from scratch takes time. |

## Attackers / failure modes we care about

1. **OVH datacentre incident** affecting one of the two physical sites
   (`web-mail`, `mx-secondary`). Probability over a 7-year window:
   non-zero (we have experienced degraded service for a few days, never full loss).
   The two servers are deliberately in different OVH datacentres.
2. **Compromise of one Internet-facing host** (`web-mail` is the more
   exposed of the two). Restore from a remote copy that the attacker
   cannot reach from the compromised host alone.
3. **Ransomware reaching the LAN** through any of: a clicked attachment,
   a vulnerable browser, a compromised piece of home-automation gear.
   The detachable USB rotation gives us a logically offline USB copy
   outside the active write window that the ransomware cannot encrypt.
5. **Silent data corruption** — data degradation on a single drive, a buggy
   filesystem, a backup script that silently stops working. Caught by
   the log scan (every night) and by the restoration tests (twice a
   month). See [`real-incidents.md`](real-incidents.md) for the actual
   instances we have detected.
6. **Operator error** — `rm -rf /important` at 14:30. Recovered from the
   rolling local archives (3 SQL dumps, 1 web archive) for fast cases,
   from the offsite copies for older state.
7. **Theft of one of the OVH disks** by a non-targeted adversary 
   (decommissioning the wrong drive, leaked spare). LUKS containers protect 
   the backup datasets at rest. However, the OS, configuration files, logs, 
   and live application data outside the LUKS containers remain readable on 
   the raw disk. Full disk encryption at the OS level (e.g. LUKS on /) is 
   not in place on these hosts, this is a known gap, acceptable given the 
   physical security guarantees of OVH datacentres and the non-targeted 
   nature of the threat.

## What this is NOT designed to protect against

These are the gaps. Stating them explicitly is important.

1. **A targeted attacker who controls both `web-mail` AND `nas-core`.**
   They get the LUKS key, they get the cleartext on the NAS. Mitigation
   would require splitting the key holders further (HSM, Vault). This is 
   currently a roadmap item.
2. **An insider with shell access on the orchestrator.** The orchestrator 
   has SSH credentials that can reach every node, including the Internet-facing 
   OVH servers. Compensating controls: outbound SSH is restricted by OPNsense 
   firewall rules to the two known OVH destination IPs only; no inbound ports 
   are open; auth events go to the SIEM; SSH keys are rotated annually.
3. **Long-term retention beyond a single rotation.** This system keeps one current 
   copy, plus 3 SQL dumps, plus 7 web archives, plus 14 monthly SQL dumps. Older state 
   is gone. Multi-year retention requires a different tool (BorgBackup, restic with 
   an immutable backend), additional storage capacity (potentially several TB), 
   ongoing storage costs, and a dedicated operational process for key management 
   and restoration testing over multi-year horizons. None of this is in scope for
   the current infrastructure size and budget.
4. **Forensic-grade write-once storage.** None of the destinations are
   append-only. An attacker with sustained access could overwrite older
   copies. Mitigation: PBS's verification job catches modified chunks
   (for the VM layer); the rotated USB drive is the only truly
   write-isolated copy.
5. **High-frequency RPO.** Backups run nightly at 00:30. Effective RPO
   is up to 24 hours of data loss in the worst case. Higher-frequency
   backups would require a different cost envelope.

## Why the layered posture

Every single layer here can fail. The MySQL daily dump can be corrupt
because the source DB was already corrupt. The rsync mirror can be
stale because cron stopped running. The LUKS key file on `nas-core` can
be inaccessible because the NAS is in a degraded state.

The point is that **no single failure breaks the recovery chain**:

| Failure                                           | Surviving copy                          |
|---------------------------------------------------|-----------------------------------------|
| `web-mail` host destroyed                         | `mx-secondary` (LUKS), `nas-core` (clear), USB |
| `mx-secondary` host destroyed                     | `web-mail`, `nas-core`, USB             |
| `nas-core` destroyed (fire, theft)                | `web-mail`, `mx-secondary`, USB (offsite) |
| Both OVH hosts destroyed simultaneously           | `nas-core` + USB                        |
| Site A destroyed (NAS + USB on-site)              | `web-mail` + `mx-secondary`             |
| Ransomware on every connected host                | The detached USB rotation               |

No exhaustive defense is claimed. The goal is a conscious, documented posture, knowing what each 
control covers, what it does not, and accepting the remaining risk with open eyes.

This is how the [3-2-1](3-2-1-strategy.md) is applied to
a small but real production setup.
