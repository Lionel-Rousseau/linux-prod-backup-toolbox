#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# nodes/web-mail/log_healthcheck.sh — out-of-band log integrity verifier
# ----------------------------------------------------------------------------
# Belt-and-braces complement to the orchestrator's outcome scan: this
# script runs locally on the web-mail node a few hours after the nightly
# campaign should have finished, and verifies for every backup log:
#   * the file exists and was modified today
#   * a "FINISH" marker for today is present in the file
#   * the file is at least MIN_SIZE bytes (a truncated log is suspicious)
#
# It exists because the orchestrator's checks happen *during* the run.
# A log corrupted *after* the run completes (filesystem issue, log
# rotation gone wrong, etc.) is invisible to it. This independent pass
# catches those.
#
# Sends a mail only on failure.
# License: MIT — see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

LOGS=(
  "/var/log/backupWebMail_NasHome.log"
  "/var/log/backupWebMail_MX2.log"
  "/var/log/backupWebApp.log"
)

MIN_SIZE="${MIN_SIZE:-1000}"
ALERT_TO="${ALERT_TO:-admin@example.org}"
ALERT_FROM="${ALERT_FROM:-root@web-mail.example.org}"
ALERT_SMTP_SERVER="${ALERT_SMTP_SERVER:-web-mail.example.org}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-465}"
ALERT_SMTP_USER="${ALERT_SMTP_USER:-admin@example.org}"
ALERT_SMTP_PASSWORD_FILE="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"

# ---- Today's expected marker ----
# rsync logs end with: "FINISH : Sat May  9 03:14:22 CEST 2026"
# We match the day-of-week + month + day-of-month to be tolerant of timezones.
DOW="$(date '+%a')"
MONTH="$(date '+%b')"
MDAY="$(date '+%-d')"
TODAY_MARKER_REGEX="FINISH[[:space:]]*:[[:space:]]*${DOW}[[:space:]]+${MONTH}[[:space:]]+${MDAY}"
TODAY_DATE="$(date '+%Y-%m-%d')"

ORIGIN="$(hostname | tr '[:lower:]' '[:upper:]')"
PROBLEMS=()

check_log() {
  local log_file="$1"

  if [ ! -f "$log_file" ]; then
    PROBLEMS+=("MISSING : $log_file")
    return
  fi

  local mtime_date
  mtime_date="$(date -r "$log_file" '+%Y-%m-%d')"
  if [ "$mtime_date" != "$TODAY_DATE" ]; then
    PROBLEMS+=("STALE   : $log_file (mtime=$mtime_date)")
  fi

  if ! grep -Eq "$TODAY_MARKER_REGEX" "$log_file"; then
    PROBLEMS+=("NOMARK  : $log_file (no FINISH for today)")
  fi

  local size
  size="$(stat -c%s "$log_file" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$MIN_SIZE" ]; then
    PROBLEMS+=("SHORT   : $log_file (${size} bytes < ${MIN_SIZE})")
  fi
}

for log in "${LOGS[@]}"; do
  check_log "$log"
done

if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  body=$(
    {
      printf '%s\n\n' "$ORIGIN log healthcheck — $TODAY_DATE"
      printf '%s\n' "${PROBLEMS[@]}"
    }
  )

  if [ -r "$ALERT_SMTP_PASSWORD_FILE" ]; then
    swaks -S \
      --to "$ALERT_TO" \
      --from "$ALERT_FROM" \
      --server "$ALERT_SMTP_SERVER" \
      --port "$ALERT_SMTP_PORT" \
      --auth LOGIN \
      --auth-user "$ALERT_SMTP_USER" \
      --auth-password "$(cat "$ALERT_SMTP_PASSWORD_FILE")" \
      --tls-on-connect \
      --h-Subject "Log healthcheck issue on $ORIGIN" \
      --body "$body" >/dev/null 2>&1 || true
  else
    echo "WARN: SMTP password file not readable, skipping mail" >&2
    echo "$body" >&2
  fi

  exit 1
fi

exit 0
