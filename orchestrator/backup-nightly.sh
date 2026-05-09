#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# backup-nightly.sh — central orchestrator for nightly backups
# ----------------------------------------------------------------------------
# Runs once a day at 00:30 (see backup-nightly.timer). Drives backup jobs on
# four endpoints, fetches their logs back, scans them for negative markers,
# and only sends mail when something is wrong.
#
# Endpoints driven from this script:
#   - nas-core          (Synology DSM, ash shell, ssh port 1249)
#   - web-mail          (Ubuntu LTS, Internet-facing, ssh port 1622)
#   - mx-secondary      (Ubuntu LTS, secondary MX + offsite, ssh port 1622)
#
# Design choices, all visible in the code below:
#   * window-based execution: every job has a hard deadline. The global
#     window closes at 23:59 of the day the run started; jobs that would
#     exceed it are skipped and flagged.
#   * SHA-256 verified config sync: we push the shared library and the
#     SMTP credentials file to every node before starting the runs. We
#     never overwrite if the destination already matches.
#   * outcome-based alerting: only abnormal outcomes mail the operator.
#     Set SEND_OK=1 to also receive the daily "OK" email if you prefer.
#   * single-flight: flock on /var/lock so two campaigns cannot overlap.
#
# License: MIT — see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail
umask 077

BASE="/root/backup-orchestrator"
LOG_DIR="/root/backup-orchestrator/log"
mkdir -p "$BASE" "$LOG_DIR"

RUN_TS="$(date +%F_%H-%M-%S)"
RUN_DIR="$LOG_DIR/$RUN_TS"
MASTER_LOG="$RUN_DIR/_master.log"
mkdir -p "$RUN_DIR"

# ---- Notification configuration ----
MAIL_TO="${BACKUP_MAIL_TO:-admin@example.org}"
SMTP_SERVER="${BACKUP_SMTP_SERVER:-web-mail.example.org}"
SMTP_PORT="${BACKUP_SMTP_PORT:-465}"
SMTP_USER="${BACKUP_SMTP_USER:-admin@example.org}"
SMTP_PASS_FILE="${BACKUP_SMTP_PASS_FILE:-$BASE/.smtp_pass}"

# 0 = mail only on failure  (default, recommended)
# 1 = also mail a daily OK summary
SEND_OK="${BACKUP_SEND_OK:-0}"

# ---- Run state ----
TOTAL_DURATION=""
WINDOW_END_EPOCH="$(date -d "$(date +%F) 23:59:00" +%s)"
STATUS=0
declare -a SUMMARY=()

# ============================================================================
# Logging helpers
# ============================================================================

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$MASTER_LOG"
}

format_duration() {
  local total="$1"
  local h m s
  h=$(( total / 3600 ))
  m=$(( (total % 3600) / 60 ))
  s=$(( total % 60 ))
  printf '%02dh:%02dm:%02ds' "$h" "$m" "$s"
}

# ============================================================================
# Remote log retrieval
# ============================================================================
# After a job finishes, we pull its log back so we can scan for negative
# markers. We use a tmpfile-and-rename pattern so a partial transfer never
# replaces a previous good log.
fetch_remote_log() {
  local host="$1"
  local port="$2"
  local remote_path="$3"
  local local_path="$4"
  local job_log="$5"

  local tmp_path="${local_path}.tmp"

  rm -f "$tmp_path"

  if [[ "$host" == "nas-core.example.net" ]]; then
    # Synology: scp to a Synology can be flaky; cat-over-ssh is safer.
    if ssh -q -T -o LogLevel=ERROR -p "$port" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=20 \
      root@"$host" "test -f '$remote_path' && cat '$remote_path'" \
      >"$tmp_path" 2>>"$job_log"; then
      mv "$tmp_path" "$local_path"
      return 0
    else
      rm -f "$tmp_path"
      return 1
    fi
  else
    if scp -P "$port" -q root@"$host":"$remote_path" "$tmp_path" >>"$job_log" 2>&1; then
      mv "$tmp_path" "$local_path"
      return 0
    else
      rm -f "$tmp_path"
      return 1
    fi
  fi
}

# ============================================================================
# Verified config sync
# ============================================================================
# Push a local file to the remote host, but only if the SHA-256 differs.
# After the upload, re-verify the destination hash. If it does not match
# the local hash, fail loudly — silent corruption is the failure mode we
# want to catch.
sync_file_to_host() {
  local host="$1"
  local local_file="$2"
  local remote_file="$3"
  local perm="$4"
  local method="$5"      # "scp" for normal hosts, "pipe" for the Synology

  local remote_dir tmp_file local_sum remote_sum
  remote_dir="$(dirname "$remote_file")"
  tmp_file="${remote_file}.tmp"

  if [ ! -r "$local_file" ]; then
    log "ERROR: local file missing or unreadable: $local_file"
    return 1
  fi

  ssh -q -T -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 root@"$host" "mkdir -p '$remote_dir'" >>"$MASTER_LOG" 2>&1 || {
    log "ERROR: cannot create $remote_dir on $host"
    return 1
  }

  local_sum="$(sha256sum "$local_file" | awk '{print $1}')"
  remote_sum="$(ssh -q -T -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 root@"$host" "test -f '$remote_file' && sha256sum '$remote_file' | awk '{print \$1}'" 2>/dev/null || true)"

  if [ "$local_sum" = "$remote_sum" ]; then
    log "$host : $(basename "$remote_file") already up to date"
    return 0
  fi

  log "$host : updating $(basename "$remote_file")"

  case "$method" in
    scp)
      scp -q "$local_file" root@"$host":"$tmp_file" >>"$MASTER_LOG" 2>&1 || {
        log "ERROR: scp upload of $(basename "$remote_file") to $host failed"
        ssh -q root@"$host" "rm -f '$tmp_file'" >>"$MASTER_LOG" 2>&1 || true
        return 1
      }
      ssh -q root@"$host" "chmod $perm '$tmp_file' && mv '$tmp_file' '$remote_file'" >>"$MASTER_LOG" 2>&1 || {
        log "ERROR: cannot finalise $(basename "$remote_file") on $host"
        ssh -q root@"$host" "rm -f '$tmp_file'" >>"$MASTER_LOG" 2>&1 || true
        return 1
      }
      ;;
    pipe)
      cat "$local_file" | ssh -q root@"$host" "cat > '$tmp_file' && chmod $perm '$tmp_file' && mv '$tmp_file' '$remote_file'" >>"$MASTER_LOG" 2>&1 || {
        log "ERROR: ssh/cat upload of $(basename "$remote_file") to $host failed"
        ssh -q root@"$host" "rm -f '$tmp_file'" >>"$MASTER_LOG" 2>&1 || true
        return 1
      }
      ;;
    *)
      log "ERROR: unknown sync method: $method"
      return 1
      ;;
  esac

  remote_sum="$(ssh -q -T -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=20 root@"$host" "sha256sum '$remote_file' | awk '{print \$1}'" 2>/dev/null || true)"
  if [ "$local_sum" != "$remote_sum" ]; then
    log "ERROR: checksum mismatch after upload of $(basename "$remote_file") to $host"
    return 1
  fi

  log "$host : $(basename "$remote_file") synced"
}

sync_support_files() {
  log "START support_files_sync"

  sync_file_to_host "web-mail.example.org"  "$BASE/luks_functions.sh" "/root/backup-orchestrator/luks_functions.sh" "700" "scp"
  sync_file_to_host "web-mail.example.org"  "$BASE/.smtp_pass"        "/root/backup-orchestrator/.smtp_pass"        "600" "scp"

  sync_file_to_host "mx-secondary.example.org" "$BASE/luks_functions.sh" "/root/backup-orchestrator/luks_functions.sh" "700" "scp"
  sync_file_to_host "mx-secondary.example.org" "$BASE/.smtp_pass"        "/root/backup-orchestrator/.smtp_pass"        "600" "scp"

  sync_file_to_host "nas-core.example.net" "$BASE/luks_functions.sh" "/root/backup-orchestrator/luks_functions.sh" "700" "pipe"
  sync_file_to_host "nas-core.example.net" "$BASE/.smtp_pass"        "/root/backup-orchestrator/.smtp_pass"        "600" "pipe"

  log "OK support_files_sync"
}

# ============================================================================
# Job runner with deadline, log fetch, and outcome assessment
# ============================================================================
run_job() {
  local name="$1"
  local host="$2"
  local port="$3"
  local timeout_s="$4"
  local marker="$5"
  local remote_logs_csv="$6"
  local remote_cmd="$7"

  local now remaining rc warn fetched_count expected_count job_log fetch_dir
  local job_start job_end job_elapsed
  local today_month today_day today_year today_regex
  now="$(date +%s)"
  remaining=$(( WINDOW_END_EPOCH - now ))

  if (( remaining <= 0 )); then
    STATUS=1
    SUMMARY+=("SKIP  $name : window 00:00-23:59 exceeded")
    log "SKIP $name : no window left"
    return
  fi

  if (( timeout_s > remaining )); then
    timeout_s="$remaining"
  fi

  job_log="$RUN_DIR/${name}.runner.log"
  fetch_dir="$RUN_DIR/$name"
  mkdir -p "$fetch_dir"

  job_start="$(date +%s)"
  log "START $name on $host:$port (timeout=${timeout_s}s)"

  rc=0
  set +e
  # Per-job lock on the remote side so a missed run cannot collide with the
  # next one. mkdir is atomic; trap removes the lock on any exit path.
  timeout --kill-after=60 "$timeout_s" \
    ssh -q -T -o LogLevel=ERROR -p "$port" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=20 \
    root@"$host" 'sh -s' >>"$job_log" 2>&1 <<EOF
LOCKDIR="/tmp/backup-orchestrator.${name}.lock"
if ! mkdir "\$LOCKDIR" 2>/dev/null; then
  echo "LOCK_BUSY"
  exit 99
fi
trap 'rmdir "\$LOCKDIR"' EXIT INT TERM
$remote_cmd
EOF
  rc=$?
  set -e

  fetched_count=0
  expected_count=0
  warn=0

  IFS=',' read -r -a logs <<< "$remote_logs_csv"
  for lg in "${logs[@]}"; do
    [[ -z "$lg" ]] && continue
    ((expected_count+=1))

    if fetch_remote_log "$host" "$port" "$lg" "$fetch_dir/$(basename "$lg")" "$job_log"; then
      ((fetched_count+=1))
    else
      echo "Remote log not found or not retrievable: $lg" >>"$job_log"
      warn=1
    fi
  done

  if (( fetched_count == 0 )); then
    echo "No log retrieved for $name" >>"$job_log"
    warn=1
  elif (( fetched_count != expected_count )); then
    echo "Incomplete log retrieval for $name: ${fetched_count}/${expected_count}" >>"$job_log"
    warn=1
  fi

  # ---- Outcome-based scan ----
  # 1. Today's date must appear in the log (reject stale logs that look fine
  #    but are actually leftovers from a run that never ran tonight).
  # 2. The success marker must be present (job actually completed).
  # 3. None of the known error strings may appear (rsync/scp errors,
  #    permission denied, broken pipe, lock busy, etc.).
  today_month="$(LC_ALL=C date '+%b')"
  today_day="$(date '+%-d')"
  today_year="$(date '+%Y')"
  today_regex="${today_month}[[:space:]]+${today_day}.*${today_year}"

  shopt -s nullglob
  for local_log in "$fetch_dir"/*; do
    if ! grep -q "$marker" "$local_log"; then
      echo "Success marker '$marker' missing in $(basename "$local_log")" >>"$job_log"
      warn=1
    fi

    if ! grep -Eq "$today_regex" "$local_log"; then
      echo "Log may not be from today in $(basename "$local_log")" >>"$job_log"
      warn=1
    fi

    if grep -Eiq '(^scp:)|(^rsync: )|(^ERROR: )|(^FAILED: )|(Permission denied)|(Connection timed out)|(Broken pipe)|(not mounted)|(LOCK_BUSY)|(No such file or directory)' "$local_log"; then
      echo "Error string detected in $(basename "$local_log")" >>"$job_log"
      warn=1
    fi
  done
  shopt -u nullglob

  job_end="$(date +%s)"
  job_elapsed=$(( job_end - job_start ))

  if (( rc == 0 && warn == 0 )); then
    if (( SEND_OK == 1 )); then
      SUMMARY+=("OK    $name")
    fi
    log "OK $name (duration=$(format_duration "$job_elapsed"))"
  else
    STATUS=1
    SUMMARY+=("FAIL  $name (rc=$rc warn=$warn)")
    log "FAIL $name (rc=$rc warn=$warn, duration=$(format_duration "$job_elapsed"))"
  fi
}

# ============================================================================
# Mailer
# ============================================================================
send_mail() {
  local subject body

  if (( STATUS == 0 )); then
    (( SEND_OK == 1 )) || return 0
    subject="[OK] Nightly backups $(date +%F)"
  else
    subject="[ALERT] Nightly backups $(date +%F)"
  fi

  body=$(
    printf 'Backup orchestrator - %s\n\n' "$(date)"
    printf 'Global result: %s\n' "$([[ $STATUS -eq 0 ]] && echo OK || echo FAILURE)"
    printf 'Total duration: %s\n\n' "${TOTAL_DURATION:-unknown}"
    printf '%s\n' "${SUMMARY[@]}"
    printf '\nLogs on orchestrator: %s\n' "$RUN_DIR"
  )

  swaks -S \
    --to "$MAIL_TO" \
    --from "root@orchestrator.example.net" \
    --server "$SMTP_SERVER" \
    --port "$SMTP_PORT" \
    --auth LOGIN \
    --auth-user "$SMTP_USER" \
    --auth-password "$(cat "$SMTP_PASS_FILE")" \
    --tls-on-connect \
    --h-Subject "$subject" \
    --body "$body" >>"$MASTER_LOG" 2>&1
}

# ============================================================================
# Main
# ============================================================================
main() {
  local run_start run_end run_elapsed
  run_start="$(date +%s)"

  # Single-flight: refuse to start if another campaign is still running.
  exec 9>/var/lock/backup-orchestrator.lock
  flock -n 9 || { log "A backup campaign is already in flight"; exit 99; }

  if (( $(date +%s) > WINDOW_END_EPOCH )); then
    log "Started after the daily window closed, aborting."
    exit 1
  fi

  if ! sync_support_files; then
    STATUS=1
    SUMMARY+=("FAIL  support_files_sync")
    log "FAIL support_files_sync"
    send_mail
    exit 1
  fi

  if (( SEND_OK == 1 )); then
    SUMMARY+=("OK    support_files_sync")
  fi

  # ---- Job 01: NAS daily replication to remote nodes ----
  run_job \
    "01_nas_core_daily" \
    "nas-core.example.net" \
    "1249" \
    "10800" \
    "FINISH :" \
    "/var/log/backupNasCore.log,/var/log/backupWebApp.log" \
    "bash /volume1/NetBackup/backup.sh"

  # ---- Job 02: web-mail node cross-replicates to mx-secondary and nas-core ----
  run_job \
    "02_web_mail_daily" \
    "web-mail.example.org" \
    "1622" \
    "9000" \
    "FINISH :" \
    "/var/log/backupWebMail_MX2.log,/var/log/backupWebMail_NasCore.log" \
    "/bin/backup"

  # ---- Job 03: web app folder + monthly DB archive ----
  run_job \
    "03_web_app" \
    "web-mail.example.org" \
    "1622" \
    "7200" \
    "FINISH :" \
    "/var/log/backupWebApp.log" \
    "/usr/bin/backup_webapp.sh"

  # ---- Job 04: mx-secondary cross-replicates to web-mail and nas-core ----
  run_job \
    "04_mx_secondary_daily" \
    "mx-secondary.example.org" \
    "1622" \
    "9000" \
    "FINISH :" \
    "/var/log/02_backupMX2_WebMail.log,/var/log/03_backupMX2_NasCore.log,/var/log/04_backupMail.log,/var/log/05_backupNasCore_WebMail.log" \
    "/usr/bin/backup"

  # ---- Job 05: NAS mirrors the consolidated set to a detachable USB ----
  run_job \
    "05_nas_core_usb" \
    "nas-core.example.net" \
    "1249" \
    "14400" \
    "Script execution took" \
    "/var/log/backupUSB.log" \
    "bash /volume1/NetBackup/mv2usb.sh"

  # ---- Job 06: monthly SQL archive (1st of the month only) ----
  if [[ "$(date +%d)" == "01" ]]; then
    run_job \
      "06_web_mail_monthly_sql" \
      "web-mail.example.org" \
      "1622" \
      "1800" \
      "Script execution took" \
      "/var/log/backupMonthlySQL.log" \
      "/usr/bin/backup_monthly_sql.sh"
  fi

  run_end="$(date +%s)"
  run_elapsed=$(( run_end - run_start ))
  log "END campaign (total duration=$(format_duration "$run_elapsed"))"
  TOTAL_DURATION="$(format_duration "$run_elapsed")"

  send_mail
  exit "$STATUS"
}

main "$@"
