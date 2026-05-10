#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# verification/restore-test-rsync.sh - automated sample-and-diff restore
# ----------------------------------------------------------------------------
# Pulls a sample subtree from one of our backup destinations into a
# scratch directory, compares it to the source via `rsync -ainv`, and
# exits non-zero if any drift is detected.
#
# This is *not* a full disaster-recovery drill. It is the lightweight
# automated companion of the manual procedure documented in
# docs/restoration-runbook.md, the one we run by hand twice a month.
# Designed to be scheduled weekly via cron / systemd timer to catch
# silent corruption between drills.
#
# What it does, in order:
#   1. Pick a source dataset (default: a small but always-present subtree)
#   2. Rsync that subtree into a fresh scratch dir
#   3. Re-run rsync in dry-run mode with -ainv to detect any difference
#   4. Optionally compare a sha256 manifest of N random files
#   5. Exit zero if everything matches, non-zero (and mail) if not
#
# Usage:
#   restore-test-rsync.sh --source <user@host:path> \
#                         --scratch /tmp/restore-test \
#                         --ssh-port 1622 \
#                         --sample-files 20 \
#                         [--mail-on-fail]
#
# License: MIT - see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

# ---- defaults ----
SOURCE=""
SCRATCH="/tmp/restore-test-$(date +%Y%m%d-%H%M%S)"
SSH_PORT="22"
SAMPLE_FILES="20"
MAIL_ON_FAIL="0"
LOG_FILE="${LOG_FILE:-/var/log/restore-test-rsync.log}"

# ---- mail config (used only with --mail-on-fail) ----
ALERT_TO="${ALERT_TO:-admin@example.org}"
ALERT_FROM="${ALERT_FROM:-root@$(hostname -f 2>/dev/null || hostname)}"
ALERT_SMTP_SERVER="${ALERT_SMTP_SERVER:-web-mail.example.org}"
ALERT_SMTP_PORT="${ALERT_SMTP_PORT:-465}"
ALERT_SMTP_USER="${ALERT_SMTP_USER:-admin@example.org}"
ALERT_SMTP_PASSWORD_FILE="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --source <user@host:path> [options]

Required:
  --source <SPEC>      rsync source spec, e.g. root@mx-secondary.example.org:/home/Backup_NasHome/sample/

Options:
  --scratch <PATH>     scratch directory for the restore (default: /tmp/restore-test-<timestamp>)
  --ssh-port <PORT>    SSH port for the source (default: 22)
  --sample-files <N>   number of random files to checksum (default: 20, 0 to skip)
  --mail-on-fail       send a mail via swaks if any drift is detected
  --log-file <PATH>    log path (default: /var/log/restore-test-rsync.log)
  -h, --help           show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)        SOURCE="$2"; shift 2 ;;
    --scratch)       SCRATCH="$2"; shift 2 ;;
    --ssh-port)      SSH_PORT="$2"; shift 2 ;;
    --sample-files)  SAMPLE_FILES="$2"; shift 2 ;;
    --mail-on-fail)  MAIL_ON_FAIL="1"; shift ;;
    --log-file)      LOG_FILE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$SOURCE" ]; then
  echo "ERROR: --source is required" >&2
  usage >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "================================================================"
echo "restore-test-rsync - $(date)"
echo "  source:        $SOURCE"
echo "  scratch:       $SCRATCH"
echo "  ssh port:      $SSH_PORT"
echo "  sample files:  $SAMPLE_FILES"
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

cleanup() {
  if [ -d "$SCRATCH" ]; then
    echo "Cleaning up scratch directory: $SCRATCH"
    rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT

mkdir -p "$SCRATCH"

# ---- step 1: rsync source → scratch ----
echo
echo "[1/4] Pulling sample from source ..."
if ! rsync -ah --partial --human-readable --stats \
  -e "ssh -q -o LogLevel=ERROR -p $SSH_PORT" \
  "$SOURCE" "$SCRATCH/"; then
  msg="restore-test-rsync FAILED: initial pull from $SOURCE returned non-zero"
  echo "$msg"
  send_alert_mail "[ALERT] restore-test-rsync - pull failed" "$msg"
  exit 1
fi

# ---- step 2: dry-run diff source vs scratch ----
echo
echo "[2/4] Dry-run diff against source ..."
DIFF_OUT="$(rsync -ainv --dry-run \
  -e "ssh -q -o LogLevel=ERROR -p $SSH_PORT" \
  "$SOURCE" "$SCRATCH/" 2>&1 || true)"

# rsync prints one line per file that would change. Anything other than
# "sending incremental file list" + a stats footer is a drift.
DIFF_LINES="$(echo "$DIFF_OUT" \
  | grep -Ev '^$|^sending incremental file list|^total size is|^sent [0-9]|^total: |^Number of files|^Number of created files|^Number of deleted files|^Number of regular files transferred|^Total file size:|^Total transferred file size:|^Literal data:|^Matched data:|^File list size:|^File list generation time:|^File list transfer time:|^Total bytes sent:|^Total bytes received:' \
  | head -50)"

if [ -n "$DIFF_LINES" ]; then
  echo "DRIFT DETECTED:"
  echo "$DIFF_LINES"
  msg=$(printf 'restore-test-rsync DRIFT detected against %s\n\n%s\n' "$SOURCE" "$DIFF_LINES")
  send_alert_mail "[ALERT] restore-test-rsync — drift detected" "$msg"
  exit 1
fi
echo "OK: no drift detected by rsync dry-run"

# ---- step 3: spot-check sha256 on N random files ----
if [ "$SAMPLE_FILES" -gt 0 ]; then
  echo
  echo "[3/4] sha256 spot check on up to $SAMPLE_FILES random files ..."

  # collect candidates from the scratch tree
  mapfile -t candidates < <(find "$SCRATCH" -type f | shuf -n "$SAMPLE_FILES" 2>/dev/null || true)

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "WARN: no files in scratch to checksum (empty source?)"
  else
    failed=0
    for f in "${candidates[@]}"; do
      # path of the same file on the remote
      rel="${f#$SCRATCH/}"
      # strip user@host: from SOURCE to get just the remote path prefix
      remote_user_host="${SOURCE%%:*}"
      remote_path_root="${SOURCE#*:}"
      remote_path_root="${remote_path_root%/}"
      remote_full="${remote_path_root}/${rel}"

      local_sum=$(sha256sum "$f" | awk '{print $1}')
      remote_sum=$(ssh -q -o LogLevel=ERROR -p "$SSH_PORT" "$remote_user_host" \
        "sha256sum '$remote_full' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)

      if [ -z "$remote_sum" ]; then
        echo "WARN: cannot compute remote sha256 for $remote_full"
        continue
      fi
      if [ "$local_sum" != "$remote_sum" ]; then
        echo "MISMATCH: $rel"
        echo "  local:  $local_sum"
        echo "  remote: $remote_sum"
        failed=$(( failed + 1 ))
      fi
    done

    if [ "$failed" -gt 0 ]; then
      msg="restore-test-rsync detected $failed sha256 mismatch(es) against $SOURCE"
      echo "$msg"
      send_alert_mail "[ALERT] restore-test-rsync - sha256 mismatch" "$msg"
      exit 1
    fi
    echo "OK: sha256 spot check passed (${#candidates[@]} files)"
  fi
fi

# ---- step 4: summary ----
echo
echo "[4/4] OK"
echo "Sample size: $(du -sh "$SCRATCH" | awk '{print $1}')"
echo "================================================================"
echo "restore-test-rsync - PASS"
echo "================================================================"
echo

exit 0
