#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# nodes/web-mail/backup_monthly_sql.sh - monthly SQL archive
# ----------------------------------------------------------------------------
# Triggered by the orchestrator on the 1st of every month. Dumps every
# database to a single SQL file under /root/backup/sql/, named with the
# year-month so old files are easy to spot. Used for compliance / accounting
# purposes (long-term retention), daily SQL dumps with shorter retention
# are produced by backup_webapp.sh.
#
# Credentials read from /root/.my.cnf via --defaults-extra-file.
# License: MIT - see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

LOG=/var/log/backupMonthlySQL.log
DEST_DIR=/root/backup/sql

start_time=$(date +%s)

mkdir -p "$DEST_DIR"

echo -e "START : $(date)\n" > "$LOG" 2>&1
echo -e "Monthly SQL dump : $(date)\n" >> "$LOG" 2>&1

cd "$DEST_DIR"

date_yyyymm="$(date +%Y-%m)"
file_name="${DEST_DIR}/Monthly_Backup-${date_yyyymm}.sql"

if mysqldump --defaults-extra-file=/root/.my.cnf --all-databases > "${file_name}"; then
  echo "SQL dumped to ${file_name}" >> "$LOG" 2>&1
  echo "Size: $(du -h "${file_name}" | awk '{print $1}')" >> "$LOG" 2>&1
else
  echo "ERROR: mysqldump failed" >> "$LOG" 2>&1
  exit 1
fi

end_time=$(date +%s)
time_elapsed=$(((end_time - start_time) / 60))
echo -e "\nFINISH : $(date)\n" >> "$LOG" 2>&1
echo "Script execution took $time_elapsed minutes." >> "$LOG" 2>&1
