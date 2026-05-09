# Verification scripts

Light-weight automated checks that complement the manual restoration
test in [`../docs/restoration-runbook.md`](../docs/restoration-runbook.md).

These scripts catch silent corruption *between* manual restoration tests. They are
intentionally narrower than a full restore and validate, more a sample-and-diff test. The goal
is problem detection, runnable weekly via cron or a systemd timer without an admin's attention.

## Contents

| Script                          | What it does                                                                                            |
|---------------------------------|---------------------------------------------------------------------------------------------------------|
| `restore-test-rsync.sh`         | Pulls a sample subtree from a backup destination, dry-run-diffs it against the source, sha256 spot check |
| `restore-test-mysql.sh`         | Replays a recent SQL dump into a throwaway database, runs structural and explicit expectations          |

## Recommended scheduling

Two example crontab entries (also in [`../examples/crontab.example`](../examples/crontab.example)):

```cron
# Weekly rsync sample-and-diff against the offsite copy on mx-secondary
30 06 * * 1  /usr/local/bin/restore-test-rsync.sh \
               --source root@mx-secondary.example.org:/home/Backup_NasCore/some/sample/ \
               --ssh-port 1622 \
               --sample-files 30 \
               --mail-on-fail

# Weekly SQL replay using the latest daily dump
00 07 * * 1  /usr/local/bin/restore-test-mysql.sh \
               --dump $(ls -t /var/backups/sql/Backup-*.sql | head -1) \
               --defaults /root/.my-restore-tester.cnf \
               --db restore_test \
               --expect-table orders=1 \
               --expect-table customers=1 \
               --mail-on-fail
```

## Exit codes

Both scripts use POSIX-friendly exit codes:

| Code | Meaning                                                             |
|------|---------------------------------------------------------------------|
| 0    | All checks passed                                                   |
| 1    | A check failed (diff detected, replay failed, expectation not met)  |
| 2    | Bad command-line arguments                                          |

Cron should mail on non-zero codes or `--mail-on-fail` should be passed for SMTP-based alerts 
via `swaks` matching the rest of the chain.
