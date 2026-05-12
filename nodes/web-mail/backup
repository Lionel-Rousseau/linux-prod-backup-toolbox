#!/bin/bash
# ----------------------------------------------------------------------------
# nodes/web-mail/backup - nightly backup orchestration on the web+mail node
# ----------------------------------------------------------------------------
# Runs on the Internet-facing web + mail server (Ubuntu LTS). Cross-
# replicates the entire root filesystem (with sensible exclusions) to:
#   * the secondary MX, on a LUKS volume opened just-in-time
#   * the Core NAS, in cleartext (LAN side, accessed over Tailscale)
#
# This is the second layer of redundancy: the web-mail server is the only
# host that can serve traffic from the Internet, so its full state must
# be reproducible elsewhere if the underlying OVH machine fails.
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

CURRENT_LOG_FILE="/var/log/backupWebMail_orchestration.log"
LOG_FILE="$CURRENT_LOG_FILE"
CURRENT_JOB_NAME="init"
CURRENT_REMOTE_HOST=""
CURRENT_REMOTE_PORT=""
CURRENT_REMOTE_MAPPER_NAME=""
CURRENT_REMOTE_LUKS_OPEN=0

# ---- rsync exclusions for the web-mail root filesystem dump ----
# Everything under /home that is itself a backup target lives here too,
# but we don't want to back up our own backups. *.crypt files are the
# LUKS containers we mount as backup destinations — never copy them.
WEB_MAIL_ROOT_RSYNC_ARGS=(
  "--delay-updates"
  "--exclude=/dev/*"
  "--exclude=/proc/*"
  "--exclude=/sys/*"
  "--exclude=/tmp/*"
  "--exclude=/lost+found"
  "--exclude=/home/Backup_*/*"
  "--exclude=/home/*.crypt"
  "--exclude=/home/tmp_crypt/*"
)

# ============================================================================
# Logging (same shape on every node)
# ============================================================================
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

# ============================================================================
# Remote LUKS wrappers
# ============================================================================
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

# ============================================================================
# rsync wrapper (rc=24 ignored)
# ============================================================================
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

# ============================================================================
# Job definition
# ============================================================================
run_rsync_daemon_with_remote_luks() {
  local job_name="$1"
  local log_file="$2"
  local src="$3"
  local dst="$4"
  local remote_host="$5"
  local remote_port="$6"
  local remote_crypt_file="$7"
  local remote_mapper_name="$8"
  shift 8
  local -a extra_rsync_args=( "$@" )
  local start_time

  CURRENT_JOB_NAME="$job_name"
  start_time="$(date +%s)"
  begin_job "$log_file"

  echo -e "\nOpening Lock\n" >>"$log_file"
  remote_prepare_luks "$remote_host" "$remote_port" "$remote_crypt_file" "$remote_mapper_name" >>"$log_file" 2>&1

  run_rsync_checked "$log_file" \
    -ah --partial --stats \
    --password-file=/root/pass2.pwd \
    -e "ssh -q -o LogLevel=ERROR -p $remote_port -T -x" \
    "${extra_rsync_args[@]}" \
    --delete \
    --stats \
    "$src" "$dst"

  echo -e "\nLocking Up\n" >>"$log_file"
  remote_close_luks "$remote_host" "$remote_port" "$remote_mapper_name" >>"$log_file" 2>&1

  finish_job "$log_file" "$start_time"
}

run_rsync_plain() {
  local job_name="$1"
  local log_file="$2"
  local src="$3"
  local dst="$4"
  local remote_port="$5"
  shift 5
  local -a extra_rsync_args=( "$@" )
  local start_time

  CURRENT_JOB_NAME="$job_name"
  start_time="$(date +%s)"
  begin_job "$log_file"

  run_rsync_checked "$log_file" \
    -ah --partial --stats \
    -e "ssh -q -o LogLevel=ERROR -p $remote_port -T -x" \
    "${extra_rsync_args[@]}" \
    --delete \
    --stats \
    "$src" "$dst"

  finish_job "$log_file" "$start_time"
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
# Job declarations
# ============================================================================

# ---- Web-mail rootfs → mx-secondary (LUKS) ----
run_rsync_daemon_with_remote_luks \
  "WebMail_on_MX2" \
  "/var/log/backupWebMail_MX2.log" \
  "/" \
  "root@mx-secondary.example.org::WebMail" \
  "mx-secondary.example.org" \
  "1622" \
  "/home/Backup_WebMail.crypt" \
  "Backup_WebMail_crypt" \
  "${WEB_MAIL_ROOT_RSYNC_ARGS[@]}"

# ---- Web-mail rootfs → nas-core (LAN, no LUKS, internal network) ----
run_rsync_plain \
  "WebMail_on_NasCore" \
  "/var/log/backupWebMail_NasCore.log" \
  "/" \
  "root@nas-core.example.net:/volume1/WebMail/" \
  "1249" \
  "${WEB_MAIL_ROOT_RSYNC_ARGS[@]}"
