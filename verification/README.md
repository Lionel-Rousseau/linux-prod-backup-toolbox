# Verification scripts

Light-weight automated checks that complement the manual restoration
drill in [`../docs/restoration-runbook.md`](../docs/restoration-runbook.md).

These scripts catch silent corruption *between* manual drills. They are
intentionally narrower than a full DR exercise — sample-and-diff or
replay-and-spot-check rather than full-restore-and-validate. The goal
is high signal at low operational cost, runnable weekly via cron or a
systemd timer without operator attention.

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
               --source root@mx-secondary.example.org:/home/Backup_NasHome/some/sample/ \
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

## What these scripts are NOT

- Not a substitute for the manual restore drill. The drill exercises
  parts of the procedure that automation cannot — your own muscle
  memory, the up-to-date-ness of the runbook, the actual state of
  destination hosts.
- Not a fitness function for the backups themselves. They verify
  consistency *between* a source and one of its mirrors. They cannot
  tell you whether the source itself is correct.
- Not a replacement for PBS's own verification job (for the VM layer).
  PBS does proper chunk-store verification; do not turn it off.

## Exit codes

Both scripts use POSIX-friendly exit codes:

| Code | Meaning                                                             |
|------|---------------------------------------------------------------------|
| 0    | All checks passed                                                   |
| 1    | A check failed (drift detected, replay failed, expectation not met) |
| 2    | Bad command-line arguments                                          |

Cron should be told to mail on non-zero (the default) or `--mail-on-fail`
should be passed for SMTP-based alerts via `swaks` matching the rest of
the chain.
