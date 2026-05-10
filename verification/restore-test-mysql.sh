#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# verification/restore-test-mysql.sh - automated SQL dump replay
# ----------------------------------------------------------------------------
# Replays a recent SQL dump from the backup chain into a throwaway
# database, then runs a few sanity queries to confirm the dump is
# structurally valid and the expected tables exist with non-zero row
# counts. Cleans up the throwaway database when done.
#
# This is the automated counterpart to the manual procedure in
# docs/restoration-runbook.md (the monthly Windows-side replay).
# Designed to run weekly via cron on a Linux test host with a local
# MySQL/MariaDB instance.
#
# Credentials for the local replay are read from a separate
# `--defaults-extra-file` so we never put plaintext passwords on the
# command line. The file should be 0600 and look like:
#
#     [client]
#     user=restore_tester
#     password=...
#     host=127.0.0.1
#
# The `restore_tester` user needs CREATE, DROP, INSERT, SELECT, ALTER,
# INDEX, REFERENCES, LOCK TABLES on the throwaway database, typically
# granted via `GRANT ALL ON restore_test.* TO 'restore_tester'@'localhost'`.
#
# Usage:
#   restore-test-mysql.sh --dump /path/to/Backup-2026-05-09.sql \
#                         --defaults /root/.my-restore-tester.cnf \
#                         --db restore_test \
#                         [--expect-table orders=1 products=10] \
#                         [--mail-on-fail]
#
# License: MIT - see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

DUMP=""
DEFAULTS_FILE=""
DB="restore_test"
EXPECTATIONS=()
MAIL_ON_FAIL="0"
LOG_FILE="${LOG_FILE:-/var/log/restore-test-mysql.log}"

ALERT_TO="${ALERT_TO:-admin@example.org}"
ALERT_FROM="${ALERT_FROM:-root@$(hostname -f 2>/dev/null || hostname)}"
ALERT_SMTP_SERVER="${ALERT_SMTP_SERVER:-web-mail.example.org}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-465}"
ALERT_SMTP_USER="${ALERT_SMTP_USER:-admin@example.org}"
ALERT_SMTP_PASSWORD_FILE="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --dump <FILE> --defaults <FILE> [options]

Required:
  --dump <PATH>          path to the SQL dump to replay
  --defaults <PATH>      path to the mysql --defaults-extra-file with credentials

Options:
  --db <NAME>            throwaway database name (default: restore_test)
  --expect-table T=N     assert that table T has at least N rows (repeatable)
  --mail-on-fail         send a mail via swaks if any check fails
  --log-file <PATH>      log path (default: /var/log/restore-test-mysql.log)
  -h, --help             show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump)         DUMP="$2"; shift 2 ;;
    --defaults)     DEFAULTS_FILE="$2"; shift 2 ;;
    --db)           DB="$2"; shift 2 ;;
    --expect-table) EXPECTATIONS+=( "$2" ); shift 2 ;;
    --mail-on-fail) MAIL_ON_FAIL="1"; shift ;;
    --log-file)     LOG_FILE="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$DUMP" ] || [ -z "$DEFAULTS_FILE" ]; then
  echo "ERROR: --dump and --defaults are required" >&2
  usage >&2
  exit 2
fi

if [ ! -r "$DUMP" ]; then
  echo "ERROR: dump file not readable: $DUMP" >&2
  exit 1
fi

if [ ! -r "$DEFAULTS_FILE" ]; then
  echo "ERROR: defaults file not readable: $DEFAULTS_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "================================================================"
echo "restore-test-mysql - $(date)"
echo "  dump:          $DUMP"
echo "  size:          $(du -h "$DUMP" | awk '{print $1}')"
echo "  defaults:      $DEFAULTS_FILE"
echo "  db:            $DB"
echo "  expectations:  ${EXPECTATIONS[*]:-(none)}"
echo "================================================================"

# ---- mailer ----
send_alert_mail() {
  local subject="$1"
  local body="$2"

  if [ "$MAIL_ON_FAIL" != "1" ]; then
    return 0
  fi
  if [ ! -r "$ALERT_SMTP_PASSWORD_FILE" ]; then
    echo "WARN: SMTP password file not readable, cannot send alert"
    return 1
  fi
  swaks -S \
    --to "$ALERT_TO" \
    --from "$ALERT_FROM" \
    --server "$ALERT_SMTP_SERVER" \
    --port "$ALERT_SMTP_PORT" \
    --auth LOGIN \
    --auth-user "$ALERT_SMTP_USER" \
    --auth-password "$(cat "$ALERT_SMTP_PASSWORD_FILE")" \
    --tls-on-connect \
    --h-Subject "$subject" \
    --body "$body" >/dev/null 2>&1 || true
}

mysql_cmd() {
  mysql --defaults-extra-file="$DEFAULTS_FILE" "$@"
}

cleanup() {
  echo "Dropping throwaway database $DB ..."
  mysql_cmd -e "DROP DATABASE IF EXISTS \`$DB\`;" || true
}
trap cleanup EXIT

# ---- step 1: prepare clean DB ----
echo
echo "[1/4] Preparing clean database $DB ..."
mysql_cmd -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\` DEFAULT CHARACTER SET utf8mb4;"

# ---- step 2: replay dump ----
echo
echo "[2/4] Replaying dump ..."
start=$(date +%s)
if ! mysql_cmd "$DB" < "$DUMP"; then
  msg="restore-test-mysql FAILED: dump replay returned non-zero for $DUMP"
  echo "$msg"
  send_alert_mail "[ALERT] restore-test-mysql - replay failed" "$msg"
  exit 1
fi
elapsed=$(( $(date +%s) - start ))
echo "OK: dump replayed in ${elapsed}s"

# ---- step 3: structural sanity ----
echo
echo "[3/4] Checking structural sanity ..."

table_count=$(mysql_cmd -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';")
echo "  tables in $DB: $table_count"
if [ "$table_count" -lt 1 ]; then
  msg="restore-test-mysql FAILED: no tables found in $DB after replay"
  echo "$msg"
  send_alert_mail "[ALERT] restore-test-mysql - no tables after replay" "$msg"
  exit 1
fi

total_rows=$(mysql_cmd -N -B -e "SELECT IFNULL(SUM(TABLE_ROWS),0) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';")
echo "  approximate rows: $total_rows"

# ---- step 4: explicit expectations ----
echo
echo "[4/4] Verifying expectations ..."
failed_expectations=0
for spec in "${EXPECTATIONS[@]}"; do
  table="${spec%%=*}"
  min_rows="${spec##*=}"
  actual=$(mysql_cmd -N -B -e "SELECT COUNT(*) FROM \`$DB\`.\`$table\`;" 2>/dev/null || echo "")
  if [ -z "$actual" ]; then
    echo "  FAIL: table $table not found"
    failed_expectations=$(( failed_expectations + 1 ))
    continue
  fi
  if [ "$actual" -lt "$min_rows" ]; then
    echo "  FAIL: table $table has $actual rows, expected at least $min_rows"
    failed_expectations=$(( failed_expectations + 1 ))
  else
    echo "  OK: table $table has $actual rows (>= $min_rows)"
  fi
done

if [ "$failed_expectations" -gt 0 ]; then
  msg="restore-test-mysql FAILED: $failed_expectations expectation(s) not met after replaying $DUMP"
  echo "$msg"
  send_alert_mail "[ALERT] restore-test-mysql - expectations failed" "$msg"
  exit 1
fi

echo
echo "================================================================"
echo "restore-test-mysql - PASS (${table_count} tables, ~${total_rows} rows, ${elapsed}s)"
echo "================================================================"
echo

exit 0
