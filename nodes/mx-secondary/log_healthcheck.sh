#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# nodes/mx-secondary/log_healthcheck.sh — out-of-band log integrity verifier
# ----------------------------------------------------------------------------
# Same logic as nodes/web-mail/log_healthcheck.sh — verifies that the
# nightly backup logs on this node are present, dated today, contain the
# success marker, and meet a minimum size. Sends mail only on failure.
#
# Run from cron a few hours after the orchestrator's expected completion,
# typically 06:00.
#
# License: MIT — see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

LOGS=(
  "/var/log/02_backupMX2_WebMail.log"
  "/var/log/03_backupMX2_NasHome.log"
  "/var/log/04_backupMail.log"
  "/var/log/05_backupNasHome_WebMail.log"
)

MIN_SIZE="${MIN_SIZE:-1000}"
ALERT_TO="${ALERT_TO:-admin@example.org}"
ALERT_FROM="${ALERT_FROM:-root@mx-secondary.example.org}"
ALERT_SMTP_SERVER="${ALERT_SMTP_SERVER:-web-mail.example.org}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-465}"
ALERT_SMTP_USER="${ALERT_SMTP_USER:-admin@example.org}"
ALERT_SMTP_PASSWORD_FILE="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"

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
