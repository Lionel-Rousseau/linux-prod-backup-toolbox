#!/bin/bash
# ----------------------------------------------------------------------------
# nodes/nas-core/backup.sh - nightly backup orchestration on the Synology NAS
# ----------------------------------------------------------------------------
# Runs on the Synology NAS (DSM 7.3.x). Driven by the central orchestrator
# over SSH. Replicates each protected dataset to the encrypted destination
# on the secondary MX (mx-secondary), opening and closing the LUKS
# container just-in-time.
#
# All cross-host copy operations:
#   * use rsync over SSH on a non-default port (1622 in production)
#   * land on a pre-mounted LUKS volume on the destination
#   * verify the rsync exit code (rc=24 is benign and silently swallowed,
#     anything else triggers the mail alert via send_fail_mail)
#
# Set LOG_FILE in the calling environment to override the default log path.
#
# License: MIT - see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"

# ---- Alert mail configuration (pulled from environment, with sane defaults) ----
ALERT_TO="${ALERT_TO:-admin@example.org}"
ALERT_FROM="${ALERT_FROM:-root@nas-core.example.net}"
ALERT_SMTP_SERVER="${ALERT_SMTP_SERVER:-web-mail.example.org}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-465}"
ALERT_SMTP_USER="${ALERT_SMTP_USER:-admin@example.org}"
ALERT_SMTP_PASSWORD_FILE="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"

# ---- Shared library ----
. /root/backup-orchestrator/luks_functions.sh

# ---- Run state ----
CURRENT_LOG_FILE="/var/log/backup_orchestration.log"
LOG_FILE="$CURRENT_LOG_FILE"
CURRENT_JOB_NAME="init"
CURRENT_REMOTE_HOST=""
CURRENT_REMOTE_PORT=""
CURRENT_REMOTE_MAPPER_NAME=""
CURRENT_REMOTE_LUKS_OPEN=0

# ============================================================================
# Logging primitives
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
# rsync wrapper - handles the "vanished file" messages
# ============================================================================
# rsync exit code 24 means "some files vanished during transfer". On a
# live filesystem (logs being rotated, mail spool, etc.) this is benign
# and not worth waking the operator up for. Anything else propagates.
run_rsync_checked() {
  local log_file="$1"
  shift
  local rsync_rc=0

  set +e
  rsync "$@" >>"$log_file" 2>&1
  rsync_rc=$?
  set -e

  case "$rsync_rc" in
    0)
      return 0
      ;;
    24)
      echo "WARNING: rsync returned rc=24 (some files vanished during transfer)" >>"$log_file"
      return 0
      ;;
    *)
      echo "ERROR: rsync failed with rc=$rsync_rc" >>"$log_file"
      return "$rsync_rc"
      ;;
  esac
}

# scp-via-rsync helper, used to copy individual files between hosts with
# the same exit-code handling as the bulk rsync runs.
run_scp_checked() {
  local log_file="$1"
  local src="$2"
  local dst="$3"
  local rsync_rc=0

  set +e
  rsync -a \
    -e "ssh -q -T -o LogLevel=ERROR -i /root/.ssh/id_ed25519 -l root -x" \
    "$src" "$dst" >>"$log_file" 2>&1
  rsync_rc=$?
  set -e

  if [ "$rsync_rc" -ne 0 ]; then
    echo "ERROR: rsync(copy) failed with rc=$rsync_rc for src=$src dst=$dst" >>"$log_file"
    return "$rsync_rc"
  fi

  return 0
}

# ============================================================================
# Remote LUKS wrappers - Destination's LUKS management
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
# Main backup primitives
# ============================================================================
# Pattern A: rsync to a remote rsync-daemon module, with the destination
# pre-mounted from a LUKS container we open here and close at the end.
run_rsync_daemon_with_remote_luks() {
  local job_name="$1"
  local log_file="$2"
  local src="$3"
  local dst="$4"
  local remote_host="$5"
  local remote_port="$6"
  local crypt_file="$7"
  local mapper_name="$8"
  shift 8
  local -a extra_rsync_args=( "$@" )
  local start_time

  CURRENT_JOB_NAME="$job_name"
  start_time="$(date +%s)"
  begin_job "$log_file"

  echo -e "\nOpening Lock\n" >>"$log_file"
  remote_prepare_luks "$remote_host" "$remote_port" "$crypt_file" "$mapper_name" >>"$log_file" 2>&1

  run_rsync_checked "$log_file" \
    -ah --partial --stats \
    --password-file=/volume1/NetBackup/pass2.pwd \
    -e "ssh -q -T -o LogLevel=ERROR -p $remote_port -i /root/.ssh/id_ed25519 -l root -x" \
    "${extra_rsync_args[@]}" \
    --delete \
    --ignore-errors \
    --human-readable \
    --stats \
    "$src" "$dst"

  echo -e "\nLocking Up\n" >>"$log_file"
  remote_close_luks "$remote_host" "$remote_port" "$mapper_name" >>"$log_file" 2>&1

  finish_job "$log_file" "$start_time"
}

# Pattern B: rsync over plain SSH (no remote rsync daemon), still with
# remote LUKS lifecycle managed from here.
run_rsync_ssh_with_remote_luks() {
  local job_name="$1"
  local log_file="$2"
  local src="$3"
  local dst="$4"
  local remote_host="$5"
  local remote_port="$6"
  local crypt_file="$7"
  local mapper_name="$8"
  shift 8
  local -a extra_rsync_args=( "$@" )
  local start_time

  CURRENT_JOB_NAME="$job_name"
  start_time="$(date +%s)"
  begin_job "$log_file"

  echo -e "\nOpening Lock\n" >>"$log_file"
  remote_prepare_luks "$remote_host" "$remote_port" "$crypt_file" "$mapper_name" >>"$log_file" 2>&1

  run_rsync_checked "$log_file" \
    -ah --partial --stats \
    -e "ssh -q -T -o LogLevel=ERROR -p $remote_port -i /root/.ssh/id_ed25519 -l root -x" \
    "${extra_rsync_args[@]}" \
    --delete \
    --ignore-errors \
    --human-readable \
    --stats \
    "$src" "$dst"

  echo -e "\nLocking Up\n" >>"$log_file"
  remote_close_luks "$remote_host" "$remote_port" "$mapper_name" >>"$log_file" 2>&1

  finish_job "$log_file" "$start_time"
}

# Pattern C: rsync to a remote daemon, no LUKS (used for non-sensitive
# datasets where the bandwidth/CPU cost of LUKS is not justified).
run_rsync_daemon_plain() {
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
    --password-file=/volume1/NetBackup/pass2.pwd \
    -e "ssh -q -T -o LogLevel=ERROR -p $remote_port -i /root/.ssh/id_ed25519 -l root -x" \
    "${extra_rsync_args[@]}" \
    --delete \
    --ignore-errors \
    --human-readable \
    --stats \
    "$src" "$dst"

  finish_job "$log_file" "$start_time"
}

# ============================================================================
# Error trap & cleanup on any failure
# ============================================================================
error_handler() {
  local line_no="$1"
  local exit_code="$2"
  local failed_cmd="${BASH_COMMAND:-unknown}"
  local body=""

  trap - ERR
  set +e

  # rsync race condition with files vanishing mid-transfer is benign.
  if [ "$exit_code" -eq 24 ] && [[ "$failed_cmd" == rsync* ]]; then
    echo "WARNING: rsync returned rc=24 (some files vanished during transfer) - no alert mail sent" >>"$CURRENT_LOG_FILE"
    return 0
  fi

  if [ -n "${CURRENT_LOG_FILE:-}" ]; then
    echo "" >>"$CURRENT_LOG_FILE"
    echo "ERROR at line ${line_no}, exit_code=${exit_code}, command=${failed_cmd}" >>"$CURRENT_LOG_FILE"
  fi

  # If we crashed with a remote LUKS volume still open, close it now.
  if [ "${CURRENT_REMOTE_LUKS_OPEN:-0}" -eq 1 ] && [ -n "${CURRENT_REMOTE_HOST:-}" ] && [ -n "${CURRENT_REMOTE_MAPPER_NAME:-}" ]; then
    {
      echo ""
      echo "Emergency remote cleanup on ${CURRENT_REMOTE_HOST} ..."
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
# Cross-replication of the consolidated NAS dataset to the secondary MX
# (offsite) and to the web-mail server (also offsite, geographically
# distinct OVH datacentre). LUKS containers on both destinations.

# ---- NasCore dataset → mx-secondary ----
run_rsync_daemon_with_remote_luks \
  "NasCore" \
  "/var/log/backupNasCore.log" \
  "/volume1/NetBackup/" \
  "root@mx-secondary.example.org::NasCore" \
  "mx-secondary.example.org" \
  1622 \
  "/home/NasCore.crypt" \
  "NasCore_crypt" \
  --exclude '@eaDir'

# ---- WebApp dataset → mx-secondary ----
run_rsync_daemon_with_remote_luks \
  "WebApp" \
  "/var/log/backupWebApp.log" \
  "/volume1/WebApp/" \
  "root@mx-secondary.example.org::WebApp" \
  "mx-secondary.example.org" \
  1622 \
  "/home/Backup_WebApp.crypt" \
  "Backup_WebApp_crypt" \
  --exclude '@eaDir'

# ---- Mail spool → web-mail (cross-encrypted at the destination) ----
run_rsync_ssh_with_remote_luks \
  "Mail" \
  "/var/log/backupMail.log" \
  "/volume1/Mail/" \
  "root@web-mail.example.org:/home/tmp_crypt/" \
  "web-mail.example.org" \
  1622 \
  "/home/Backup_Mail.crypt" \
  "Backup_Mail_crypt" \
  --exclude '@eaDir'
