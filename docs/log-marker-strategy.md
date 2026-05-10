# Log-marker strategy

Why does the orchestrator scan logs for specific strings instead of just
trusting exit codes? Experience has showed me that exit codes  cannot 
fully be  trusted, at leat, with the tools I'm using.

## The four checks

For every log file the orchestrator pulls back from a remote node, four
assertions must hold. Any one of them failing promotes the run to
`FAIL` and triggers an alert mail.

### 1. The file must exist and be retrievable

If `scp` or `cat-over-ssh` cannot get the log, something is wrong even
if the remote command exited zero, the log path may have moved, the
filesystem may be full, the SSH session may have been killed mid-run.

### 2. The success marker must be present

Every backup script ends its log with:

```
FINISH : <date>
```

If the success marker is absent, the script crashed somewhere between
the start and the end. The exit code might still be zero (the trap may
have swallowed it, the script may have run in a subshell, etc.),but
no marker means no completion.

### 3. The log must be from today

A log that exists, is fully formed, contains the success marker, and is
five days old, is **not** evidence that anything happened tonight. It
is a leftover from the last successful run.

The check uses a regex on the locale-normalised date format that the
backup scripts emit (`Mon May  9 03:14:22 CEST 2026`):

```
${month_abbrev}[[:space:]]+${day_of_month}.*${year}
```

This catches the silent failure where cron is broken, the timer is
broken, or the script is somehow launched but immediately returns
without writing.

### 4. No known error string may appear

A log can satisfy the first three checks and still contain damning
output buried in the middle. The orchestrator's regex is:

```
(^scp:)|(^rsync: )|(^ERROR: )|(^FAILED: )|(Permission denied)|
(Connection timed out)|(Broken pipe)|(not mounted)|(LOCK_BUSY)|
(No such file or directory)
```

This list grew over time. Each entry is a real failure mode that was
detected and added after an incident. The list is the operational 
memory of the system.

## Why not exit codes?

Exit codes are checked too, they are the first signal. The remote
command runs under `set -Eeuo pipefail`, an `ERR` trap, and `timeout`,
so a non-zero exit reliably is sent back to the orchestrator. But
**exit codes only tell you whether the script crashed**, not whether
the *work* happened. 

The success marker check, the date check, and the error-string check
each catch a subset of these failures that the exit code alone would
miss.

## Only failure mails

A normal night produces zero email traffic. The operator gets a mail
**only** when something is wrong. This is deliberate: if a mail arrives, 
it means action is needed and it avoids alert fatigue.

The counterpart is that regular checks is mandatory, silent failures will find the gaps.
