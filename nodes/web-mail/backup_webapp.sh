#!/bin/bash
# ----------------------------------------------------------------------------
# nodes/web-mail/backup_webapp.sh - web app folder + DB rolling archives
# ----------------------------------------------------------------------------
# Runs on the web+mail node. Three things, in order:
#   1. rsync the live document root to the secondary MX (LUKS volume)
#   2. build a dated, compressed snapshot of the document root, and a fresh
#      mysqldump --all-databases of the local DB. Keep 1 web archive and
#      the last 3 SQL dumps locally (for fast rollback).
#   3. push both archives to the secondary MX (separate LUKS volumes,
#      retention windows: 7 web archives, 14 SQL archives).
#
# Why a separate script: the rolling archives serve a different purpose
# from the rsync mirror. rsync mirrors the *current* state, useful for
# disaster recovery, useless for "I broke something at 14:30, give me the
# state of 06:00". The dated archives cover that gap.
#
# Secrets handling
# ----------------
# `mysqldump` reads its credentials from /root/.my.cnf (0600 file) with:
#
#     [mysqldump]
#     user=backup_dump
#     password=...
#     host=127.0.0.1
#
# License: MIT - see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

ALERT_TO="${ALERT_TO:-admin@example.org}"
ALERT_FROM="${ALERT_FROM:-root@web-mail.example.org}"
ALERT_SMTP_SERVER="${ALERT_SMTP_SERVER:-web-mail.example.org}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-465}"
ALERT_SMTP_USER="${ALERT_SMTP_USER:-admin@example.org}"
ALERT_SMTP_PASSWORD_FILE="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"

. /root/backup-orchestrator/luks_functions.sh

CURRENT_LOG_FILE="/var/log/backupWebApp.log"
LOG_FILE="$CURRENT_LOG_FILE"
CURRENT_JOB_NAME="init"
CURRENT_REMOTE_HOST=""
CURRENT_REMOTE_PORT=""
CURRENT_REMOTE_MAPPER_NAME=""
CURRENT_REMOTE_LUKS_OPEN=0

REMOTE_MX2_HOST="mx-secondary.example.org"
REMOTE_MX2_PORT=1622
LOCAL_ARCHIVE_ROOT="/root"
WEBROOT="/var/www/html"

set_log_file() {
  CURRENT_LOG_FILE="$1"
  LOG_FILE="$1"
  export LOG_FILE
}

begin_job() {
  local log_file="$1"
  set_log_file "$log_file"
  echo -e "START : $(date)\n" >"$log_file" 2>&1
}

finish_job() {
  local log_file="$1"
  local start_time="$2"
  local end_time
  local time_elapsed

  echo -e "\nFINISH : $(date)\n\n" >>"$log_file"
  end_time="$(date +%s)"
  time_elapsed=$(((end_time-start_time)/60))
  echo "Script execution took $time_elapsed minutes." >>"$log_file" 2>&1
}

remote_prepare_luks() {
  local remote_host="$1"
  local remote_port="$2"
  local crypt_file="$3"
  local mapper_name="$4"

  CURRENT_REMOTE_HOST="$remote_host"
  CURRENT_REMOTE_PORT="$remote_port"
  CURRENT_REMOTE_MAPPER_NAME="$mapper_name"
  CURRENT_REMOTE_LUKS_OPEN=1

  ssh -q -T -p "$remote_port" -o LogLevel=ERROR root@"$remote_host" 'bash -s' <<EOF
set -Eeuo pipefail
LOG_FILE="/var/log/${mapper_name}.remote.log"
. /root/backup-orchestrator/luks_functions.sh
prepare_luks_mount "ssh -q -T -o LogLevel=ERROR nas-core 'cat /volume1/NetBackup/.ash'" "$crypt_file" "$mapper_name" "/home/tmp_crypt"
EOF
}

remote_close_luks() {
  local remote_host="$1"
  local remote_port="$2"
  local mapper_name="$3"

  ssh -q -T -p "$remote_port" -o LogLevel=ERROR root@"$remote_host" 'bash -s' <<EOF
set -Eeuo pipefail
LOG_FILE="/var/log/${mapper_name}.remote.log"
. /root/backup-orchestrator/luks_functions.sh
close_luks_mount "$mapper_name" "/home/tmp_crypt"
assert_no_backup_luks_left_open "/home/tmp_crypt"
EOF

  CURRENT_REMOTE_LUKS_OPEN=0
  CURRENT_REMOTE_HOST=""
  CURRENT_REMOTE_PORT=""
  CURRENT_REMOTE_MAPPER_NAME=""
}

run_rsync_checked() {
  local log_file="$1"
  shift
  local rsync_rc=0

  set +e
  rsync "$@" >>"$log_file" 2>&1
  rsync_rc=$?
  set -e

  case "$rsync_rc" in
    0)  return 0 ;;
    24) echo "WARNING: rsync returned rc=24 (some files vanished during transfer)" >>"$log_file"; return 0 ;;
    *)  echo "ERROR: rsync failed with rc=$rsync_rc" >>"$log_file"; return "$rsync_rc" ;;
  esac
}

run_scp_checked() {
  local log_file="$1"
  local port="$2"
  shift 2

  set +e
  scp -q -P "$port" "$@" >>"$log_file" 2>&1
  local scp_rc=$?
  set -e

  if [ "$scp_rc" -ne 0 ]; then
    echo "ERROR: scp failed with rc=$scp_rc" >>"$log_file"
    return "$scp_rc"
  fi

  return 0
}
# ============================================================================
# Job 1: rsync live web folder to mx-secondary (LUKS)
# ============================================================================
run_webfolder_rsync_to_mx2() {
  local log_file="$1"

  echo -e "\n\n\n---Rsyncing WebFolder\n" >>"$log_file" 2>&1
  echo -e "\nOpening Lock\n" >>"$log_file" 2>&1

  remote_prepare_luks "$REMOTE_MX2_HOST" "$REMOTE_MX2_PORT" "/home/Backup_WebApp.crypt" "Backup_WebApp_crypt" >>"$log_file" 2>&1

  echo -e "RSync WebFolder : $(date)\n" >>"$log_file" 2>&1
  run_rsync_checked "$log_file" \
    -ah --partial --stats \
    --password-file=/root/pass2.pwd \
    -e "ssh -q -o LogLevel=ERROR -p $REMOTE_MX2_PORT -i /root/.ssh/id_ed25519 -l root -T -x" \
    "$WEBROOT/" \
    "root@${REMOTE_MX2_HOST}::WebApp" \
    --delete \
    --ignore-errors \
    --human-readable \
    --stats

  echo -e "\nLocking Up\n" >>"$log_file" 2>&1
  remote_close_luks   "$REMOTE_MX2_HOST" "$REMOTE_MX2_PORT" "Backup_WebApp_crypt" >>"$log_file" 2>&1
}

# ============================================================================
# Job 2: build local dated archives (web folder + SQL dump)
# ============================================================================
build_local_archives() {
  local log_file="$1"
  local now folname db_name date_time file_name

  echo -e "\n\n\n---Archiving WebFolder and DB\n" >>"$log_file" 2>&1

  now="$(date +'%Y_%m_%d')"
  folname="bck_${now}"

  echo -e "\nArchiving WebFolder : $(date)\n" >>"$log_file" 2>&1
  rm -Rf "${LOCAL_ARCHIVE_ROOT}/${folname}/"
  mkdir -p "${LOCAL_ARCHIVE_ROOT}/${folname}"
  cp -a "$WEBROOT/." "${LOCAL_ARCHIVE_ROOT}/${folname}"
  GZIP=-9 tar -c -z -f "${LOCAL_ARCHIVE_ROOT}/${folname}.tar.gz" "${LOCAL_ARCHIVE_ROOT}/${folname}" >>"$log_file" 2>&1

  echo -e "\nMySQL Dump : $(date)\n" >>"$log_file" 2>&1
  cd "${LOCAL_ARCHIVE_ROOT}/"
  db_name="${LOCAL_ARCHIVE_ROOT}/Backup-"
  date_time="$(date +%Y-%m-%d_%H:%M:%S)"
  file_name="${db_name}${date_time}.sql"

  # Credentials read from /root/.my.cnf (mode 0600).
  # The dedicated `backup_dump` user has SELECT/LOCK TABLES only.
  mysqldump --defaults-extra-file=/root/.my.cnf --all-databases > "${file_name}"

  # ---- Local retention: keep last 3 SQL dumps and 1 web archive folder ----
  ls -t Backup-*    2>/dev/null | tail -n +4 | xargs -r rm --
  ls -t -d bck_*    2>/dev/null | tail -n +2 | xargs -r rm -Rf --

  echo -e "\nSCP Tasks : $(date)\n" >>"$log_file" 2>&1
}

# ============================================================================
# Job 3a: push SQL archives to mx-secondary (LUKS)
# ============================================================================
push_sql_archives_to_mx2() {
  local log_file="$1"
  local -a sql_files=()

  echo -e "\n\n\n---SQL push\n" >>"$log_file" 2>&1
  echo -e "\nOpening Lock\n" >>"$log_file" 2>&1

  remote_prepare_luks "$REMOTE_MX2_HOST" "$REMOTE_MX2_PORT" "/home/Backup_WebAppSQL.crypt" "Backup_WebAppSQL_crypt" >>"$log_file" 2>&1

  # ---- Remote retention: keep last 14 SQL dumps offsite ----
  ssh -q -o LogLevel=ERROR -p "$REMOTE_MX2_PORT" root@"$REMOTE_MX2_HOST" 'cd /home/tmp_crypt/ && ls -t Backup-* 2>/dev/null | tail -n +15 | xargs -r rm --' >>"$log_file" 2>&1
  ssh -q -o LogLevel=ERROR -p "$REMOTE_MX2_PORT" root@"$REMOTE_MX2_HOST" 'df -h /home/tmp_crypt; df -ih /home/tmp_crypt; mount | grep "/home/tmp_crypt"' >>"$log_file" 2>&1

  shopt -s nullglob
  sql_files=( $(ls -t "${LOCAL_ARCHIVE_ROOT}"/Backup-*.sql 2>/dev/null | head -n 1) )
  shopt -u nullglob

  if [ "${#sql_files[@]}" -eq 0 ]; then
    echo "ERROR: no SQL file to transfer (${LOCAL_ARCHIVE_ROOT}/Backup-*.sql)" >>"$log_file"
    return 1
  fi

  run_scp_checked "$log_file" "$REMOTE_MX2_PORT" "${sql_files[@]}" root@"${REMOTE_MX2_HOST}":/home/tmp_crypt/

  echo "OK: SCP and remote retention done" >>"$log_file" 2>&1
  echo -e "\nLocking Up\n" >>"$log_file" 2>&1

  remote_close_luks   "$REMOTE_MX2_HOST" "$REMOTE_MX2_PORT" "Backup_WebAppSQL_crypt" >>"$log_file" 2>&1
}

# ============================================================================
# Job 3b: push web archives to mx-secondary (LUKS)
# ============================================================================
push_web_archives_to_mx2() {
  local log_file="$1"
  local -a web_files=()

  echo -e "\n\n\n---Web archive push\n" >>"$log_file" 2>&1
  echo -e "\nOpening Lock\n" >>"$log_file" 2>&1

  remote_prepare_luks "$REMOTE_MX2_HOST" "$REMOTE_MX2_PORT" "/home/Backup_WebAppArchive.crypt" "Backup_WebAppArchive_crypt" >>"$log_file" 2>&1

  shopt -s nullglob
  web_files=( "${LOCAL_ARCHIVE_ROOT}"/bck_*.tar.gz )
  shopt -u nullglob

  if [ "${#web_files[@]}" -eq 0 ]; then
    echo "ERROR: no web archive to transfer (${LOCAL_ARCHIVE_ROOT}/bck_*.tar.gz)" >>"$log_file"
    return 1
  fi

  run_scp_checked "$log_file" "$REMOTE_MX2_PORT" "${web_files[@]}" root@"${REMOTE_MX2_HOST}":/home/tmp_crypt/

  # ---- Remote retention: keep last 7 web archives offsite ----
  ssh -q -o LogLevel=ERROR -p "$REMOTE_MX2_PORT" root@"$REMOTE_MX2_HOST" 'cd /home/tmp_crypt/ && ls -t -d bck_* 2>/dev/null | tail -n +8 | xargs -r rm -Rf --' >>"$log_file" 2>&1

  echo "OK: SCP and remote retention done" >>"$log_file" 2>&1
  echo -e "\nLocking Up\n" >>"$log_file" 2>&1

  remote_close_luks   "$REMOTE_MX2_HOST" "$REMOTE_MX2_PORT" "Backup_WebAppArchive_crypt" >>"$log_file" 2>&1
}

# ============================================================================
# Error trap
# ============================================================================
error_handler() {
  local line_no="$1"
  local exit_code="$2"
  local failed_cmd="${BASH_COMMAND:-unknown}"
  local body=""

  trap - ERR
  set +e

  if [ "$exit_code" -eq 24 ] && [[ "$failed_cmd" == rsync* ]]; then
    echo "WARNING: rsync returned rc=24 (some files vanished during transfer) - no alert mail sent" >>"$CURRENT_LOG_FILE"
    return 0
  fi

  if [ -n "${CURRENT_LOG_FILE:-}" ]; then
    echo "" >>"$CURRENT_LOG_FILE"
    echo "ERROR at line ${line_no}, exit_code=${exit_code}, command=${failed_cmd}" >>"$CURRENT_LOG_FILE"
  fi

  if [ "${CURRENT_REMOTE_LUKS_OPEN:-0}" -eq 1 ] && [ -n "${CURRENT_REMOTE_HOST:-}" ] && [ -n "${CURRENT_REMOTE_MAPPER_NAME:-}" ]; then
    {
      echo ""
      echo "Emergency remote cleanup on ${CURRENT_REMOTE_HOST} for ${CURRENT_REMOTE_MAPPER_NAME} ..."
    } >>"$CURRENT_LOG_FILE" 2>&1

    remote_close_luks "$CURRENT_REMOTE_HOST" "$CURRENT_REMOTE_PORT" "$CURRENT_REMOTE_MAPPER_NAME" >>"$CURRENT_LOG_FILE" 2>&1 || true
    CURRENT_REMOTE_LUKS_OPEN=0
    CURRENT_REMOTE_HOST=""
    CURRENT_REMOTE_PORT=""
    CURRENT_REMOTE_MAPPER_NAME=""
  fi

  body="$(
    {
      printf 'Host: %s\n' "$HOST_FQDN"
      printf 'Script: %s\n' "$SCRIPT_NAME"
      printf 'Job: %s\n' "$CURRENT_JOB_NAME"
      printf 'Date: %s\n' "$(date)"
      printf 'Line: %s\n' "$line_no"
      printf 'Exit code: %s\n' "$exit_code"
      printf 'Command: %s\n' "$failed_cmd"
      printf '\nLast log lines:\n\n'
      tail -n 120 "$CURRENT_LOG_FILE" 2>/dev/null || true
    }
  )"

  send_fail_mail "[ALERT] ${SCRIPT_NAME} / ${CURRENT_JOB_NAME} on ${HOST_FQDN}" "$body" || true
  exit "$exit_code"
}

trap 'error_handler "$LINENO" "$?"' ERR

# ============================================================================
# Main
# ============================================================================
main() {
  local start_time
  local log_file="/var/log/backupWebApp.log"

  CURRENT_JOB_NAME="backup_webapp"
  start_time="$(date +%s)"
  begin_job "$log_file"

  run_webfolder_rsync_to_mx2 "$log_file"
  build_local_archives        "$log_file"
  push_sql_archives_to_mx2    "$log_file"
  push_web_archives_to_mx2    "$log_file"

  finish_job "$log_file" "$start_time"
}

main "$@"
