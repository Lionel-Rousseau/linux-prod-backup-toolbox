# Restoration runbook

This document is the actual procedure used to validate that the backups are restorable and that is
performed at least twice a month, on rotating datasets and rotating source hosts.

The deliberate choice here is **manual**, not automated. Automated
restoration tests are a great idea on paper but in practice, for a small
infrastructure, they tend to silently drift out of sync.
Doing the restore by hand twice a month means:

- I notice when the procedure stops working (mismatched paths, expired
  keys, broken assumptions).
- I'm kept informed on the actual recovery flow rather than trusting a
  green light from a test that may or may not return the right thing.
- The two NEW scripts in [`../verification/`](../verification/)
  are the *partial* automation of a sample and diff, not a
  full restore and validation. They catch silent corruption between manual
  restorations.

## Restore environments

Two scratch areas exist permanently:

| Where                                    | Used for                                            |
|------------------------------------------|-----------------------------------------------------|
| `nas-core:/volume1/Restore`              | Filesystem-level restores (from the NAS). About 500 GB. |
| `proxmox-test`, dedicated Proxmox node   | VM restoration tests via PBS, also used for general tests. about 1TB. |

Restored data lives in these scratch areas only, never overwriting
production. Files can be diffed against production with `rsync -ainv`
to confirm parity.

## Frequency

| What                            | How often       | Source                                   |
|---------------------------------|-----------------|------------------------------------------|
| One VM (rotating)               | 2× per month    | PBS chunk store                          |
| One filesystem dataset (rotating) | 2× per month  | One of: NAS rsync mirror, OVH LUKS mirror, USB |
| Monthly SQL dump replay         | 1× per month    | Latest monthly archive, restored on a Windows test workstation against a local MySQL |
| Full RPi image flash test       | 2× per year     | Latest .img from `mx-secondary` or NAS rsync mirror |

## Procedure — filesystem on Synology side

```bash
# 1. Identify the source : the dataset to restore today
SRC="/volume1/MX2"          # for example: the mx-secondary mirror
DST="/volume1/Restore/MX2-test-$(date +%F)"

# 2. Allocate a clean scratch directory
mkdir -p "$DST"

# 3. Replay the rsync, no --delete, into the scratch directory
rsync -ah --partial --human-readable --stats "$SRC/" "$DST/"

# 4. Validity checks (size, recent file, known file)
du -sh "$SRC" "$DST"
find "$DST" -type f -mtime -2 | head
ls -l "$DST/known/marker/file"  # something we expect to find

# 5. Spot-diff against the source (no changes expected)
rsync -ainv "$SRC/" "$DST/" | head -20

# 6. Cleaning
rm -rf "$DST"
```

Or, more compact, using
[`verification/restore-test-rsync.sh`](../verification/restore-test-rsync.sh)
which encodes the same flow with explicit success/failure exit codes.

## Procedure — filesystem on offsite LUKS side

The same idea, but from the destination side, exercising the LUKS open
path:

```bash
# On mx-secondary
. /root/backup-orchestrator/luks_functions.sh
prepare_luks_mount \
  "ssh -q nas-core 'cat /volume1/NetBackup/.ash'" \
  /home/Backup_NasCore.crypt \
  Backup_NasCore_crypt \
  /home/tmp_crypt

# Restore a sample to scratch
mkdir -p /tmp/restore-test
rsync -ah --partial /home/tmp_crypt/some/dir/ /tmp/restore-test/
ls -l /tmp/restore-test/
# inspect, diff, sanity-check

# cleaning : close the container, remove scratch
close_luks_mount Backup_NasCore_crypt /home/tmp_crypt
assert_no_backup_luks_left_open /home/tmp_crypt
rm -rf /tmp/restore-test
```

## Procedure for MySQL dump replay (Windows side)

The monthly SQL archive is restored on a Windows 11 test workstation
against a local MySQL Server. This validates two things at once: that
the dump is structurally valid, and that no Linux-specific behaviour
sneaks into the dump (collation conflicts, AUTO_INCREMENT mismatches).

```powershell
# 1. Pull the latest monthly archive
scp -P 1622 root@web-mail.example.org:/root/backup/sql/Monthly_Backup-2026-05.sql .

# 2. Create a throwaway database
"DROP DATABASE IF EXISTS restore_test; CREATE DATABASE restore_test;" | mysql -u root -p

# 3. Replay
Get-Content Monthly_Backup-2026-05.sql | mysql -u root -p restore_test

# 4. Validity checks
"SELECT COUNT(*) FROM restore_test.orders;" | mysql -u root -p

# 5. Cleaning
"DROP DATABASE restore_test;" | mysql -u root -p
```

Or, on a Linux test node, the same flow is automated in
[`verification/restore-test-mysql.sh`](../verification/restore-test-mysql.sh).

## Procedure — VM restore via PBS

PBS handles its own integrity verification continuously, so the manual
test is a chunk-store restore exercise:

```bash
# On proxmox-test
# 1. List available snapshots
proxmox-backup-client snapshot list --repository <PBS-repo>

# 2. Restore a recent VM snapshot to a fresh VMID
qmrestore <vma file> 999  # 999 = test VMID

# 3. Boot the restored VM and verify it starts cleanly:
#    - No kernel panic or crash at boot
#    - Key services are running (check systemctl status)
#    - Web UI is reachable where applicable (OPNsense, Zabbix, Wazuh)
#    Note: network-dependent checks (gateways, agent data, RADIUS clients)
#    are not meaningful on the test node, the goal is to confirm the
#    backup is uncorrupted and the VM is bootable, not full functionality.

# 4. Cleaning VM
qm destroy 999
```

## Real-incident appendix

What this procedure has actually caught is in
[`real-incidents.md`](real-incidents.md).

---

**Operational reality check.** The procedure above takes 30-60 minutes
per drill, twice a month, plus the monthly DB replay (~20 min). It is
not free. It is also the cheapest insurance for the backup chain.
