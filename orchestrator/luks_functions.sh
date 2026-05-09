#!/bin/bash
# ----------------------------------------------------------------------------
# luks_functions.sh
# ----------------------------------------------------------------------------
# Idempotent helpers for LUKS container open/close, with a strong contract:
#  * Always start by cleaning up anything that should not be there
#    (mounted leftover, mapper still open) before doing anything else.
#  * On any failure path, attempt to close what we opened so a crashed
#    run never leaves a decrypted volume mounted.
#  * Never persist the LUKS key file to disk on the host — read it from
#    a `key_cmd` that fetches it just-in-time over SSH from a third host.
#
# Sourced by every node that needs to open a LUKS container during a
# backup run (web-mail, mx-secondary, the orchestrator). Also usable
# stand-alone if you want to inspect or close a stale mapper from a
# shell.
#
# Optional environment variables consumed by callers:
#   LOG_FILE               path to write structured log lines
#   ALERT_TO               recipient of the failure mail
#   ALERT_FROM             envelope sender
#   ALERT_SMTP_SERVER      SMTPS server hostname
#   ALERT_SMTP_PORT        465 (implicit TLS) or 587 (STARTTLS)
#   ALERT_SMTP_USER        SMTP authentication user
#   ALERT_SMTP_PASSWORD_FILE  path to a file containing the SMTP password
#   BACKUP_MAPPER_REGEX    regex matching mappers we are allowed to close
#   MOUNT_POINT_DEFAULT    where to mount opened containers (default: /core/tmp_crypt)
#   DOCKER_BIN             path to docker (Synology fallback for swaks)
#
# License: MIT — see LICENSE in the repository root.
# ----------------------------------------------------------------------------

BACKUP_MAPPER_REGEX="${BACKUP_MAPPER_REGEX:-^(Backup_.*_crypt|NasCore_crypt)$}"
MOUNT_POINT_DEFAULT="${MOUNT_POINT_DEFAULT:-/home/tmp_crypt}"
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
DOCKER_BIN="${DOCKER_BIN:-/usr/local/bin/docker}"

host_fqdn() {
  hostname -f 2>/dev/null || hostname
}

log_msg() {
  local msg="$*"
  if [ -n "${LOG_FILE:-}" ]; then
    printf '[%s] %s\n' "$(date '+%F %T')" "$msg" >>"$LOG_FILE"
  else
    printf '[%s] %s\n' "$(date '+%F %T')" "$msg" >&2
  fi
}

log_cmd_output() {
  if [ -n "${LOG_FILE:-}" ]; then
    "$@" >>"$LOG_FILE" 2>&1
  else
    "$@" >&2
  fi
}

default_alert_from() {
  printf 'root@%s' "$(host_fqdn)"
}

is_synology() {
  [ -f /etc.defaults/VERSION ]
}

# Run swaks natively, or fall back to a Docker container on Synology where
# `swaks` is not in the package repository. Last resort: return 127 so the
# caller can choose what to do.
run_swaks_cmd() {
  if command -v swaks >/dev/null 2>&1; then
    swaks "$@"
    return $?
  fi

  if is_synology && [ -x "$DOCKER_BIN" ]; then
    log_msg "INFO: native swaks not found, using ascentiotech/swaks via $DOCKER_BIN"
    "$DOCKER_BIN" run --rm --pull never --network host \
      -e TZ="${TZ:-Europe/Paris}" \
      ascentiotech/swaks "$@"
    return $?
  fi

  return 127
}

send_fail_mail() {
  local subject="$1"
  local body="$2"
  local alert_to="${ALERT_TO:-admin@example.org}"
  local alert_from="${ALERT_FROM:-$(default_alert_from)}"
  local alert_smtp_server="${ALERT_SMTP_SERVER:-web-mail.example.org}"
  local alert_smtp_port="${ALERT_SMTP_PORT:-465}"
  local alert_smtp_user="${ALERT_SMTP_USER:-admin@example.org}"
  local alert_smtp_password_file="${ALERT_SMTP_PASSWORD_FILE:-/root/backup-orchestrator/.smtp_pass}"
  local smtp_password=""
  local -a tls_opts

  if [ ! -r "$alert_smtp_password_file" ]; then
    log_msg "WARN: SMTP password file not found or not readable: $alert_smtp_password_file"
    return 1
  fi

  smtp_password="$(cat "$alert_smtp_password_file")"

  case "$alert_smtp_port" in
    465) tls_opts=(--tls-on-connect) ;;
    *)   tls_opts=(--tls) ;;
  esac

  if ! run_swaks_cmd \
    -S \
    --to "$alert_to" \
    --from "$alert_from" \
    --server "$alert_smtp_server" \
    --port "$alert_smtp_port" \
    --auth LOGIN \
    --auth-user "$alert_smtp_user" \
    --auth-password "$smtp_password" \
    "${tls_opts[@]}" \
    --h-Subject "$subject" \
    --body "$body" >/dev/null 2>&1; then

    if command -v swaks >/dev/null 2>&1; then
      log_msg "WARN: failed to send alert mail via native swaks."
    elif is_synology && [ -x "$DOCKER_BIN" ]; then
      log_msg "WARN: failed to send alert mail via Docker swaks ($DOCKER_BIN)."
    else
      log_msg "WARN: swaks not found and no Docker fallback, cannot send alert mail."
    fi
    return 1
  fi

  return 0
}

# List currently-open dm-crypt mappers whose name matches our backup regex.
# We deliberately scope to a name pattern so we never accidentally close a
# mapper that belongs to something else (root FS encryption, etc.).
list_open_backup_mappers() {
  lsblk -nrpo NAME,TYPE 2>/dev/null \
    | awk '$2=="crypt"{gsub(".*/","",$1); print $1}' \
    | grep -E "$BACKUP_MAPPER_REGEX" || true
}

is_mapper_open() {
  local mapper_name="$1"
  cryptsetup status "$mapper_name" >/dev/null 2>&1
}

mounted_source_on_tmp_crypt() {
  local mount_point="${1:-$MOUNT_POINT_DEFAULT}"
  if mountpoint -q "$mount_point"; then
    findmnt -rn -M "$mount_point" -o SOURCE
  else
    return 1
  fi
}

# Always-safe pre-state: nothing mounted on $mount_point, no backup mappers
# open. Called both before opening a fresh container and at the end of
# every job, so a crash in the middle still produces a clean state on the
# next run.
cleanup_tmp_crypt_and_backup_mappers() {
  local mount_point="${1:-$MOUNT_POINT_DEFAULT}"
  local current_src=""
  local mapper=""

  mkdir -p "$mount_point" || {
    log_msg "ERROR: cannot create $mount_point"
    return 1
  }

  # 1) unmount $mount_point if mounted
  if mountpoint -q "$mount_point"; then
    current_src="$(findmnt -rn -M "$mount_point" -o SOURCE 2>/dev/null || true)"
    log_msg "Mount detected on ${mount_point}: ${current_src:-unknown}"
    log_msg "Attempting to unmount ${mount_point}"

    sync
    if ! umount "$mount_point"; then
      log_msg "ERROR: cannot unmount ${mount_point}"
      if command -v fuser >/dev/null 2>&1; then
        log_msg "Processes using ${mount_point}:"
        log_cmd_output fuser -vm "$mount_point" || true
      fi
      return 1
    fi
  fi

  # 2) close any backup mapper still open
  while IFS= read -r mapper; do
    [ -n "$mapper" ] || continue
    log_msg "Closing leftover backup mapper: $mapper"

    if ! cryptsetup close "$mapper"; then
      log_msg "ERROR: cannot close $mapper"
      return 1
    fi
  done < <(list_open_backup_mappers)

  # 3) final assertions
  if mountpoint -q "$mount_point"; then
    log_msg "ERROR: ${mount_point} is still mounted after cleanup"
    log_cmd_output findmnt -rn -M "$mount_point" -o SOURCE,TARGET,FSTYPE,OPTIONS || true
    return 1
  fi

  if list_open_backup_mappers | grep -q .; then
    log_msg "ERROR: at least one backup mapper is still open after cleanup"
    log_cmd_output bash -lc 'lsblk -nrpo NAME,TYPE | awk '"'"'$2=="crypt"{print $0}'"'"'' || true
    return 1
  fi

  return 0
}

# Open a LUKS container and mount it on $mount_point.
# `key_cmd` is a shell command that prints the key on stdout — typically
# `ssh -q nas-core 'cat /volume1/NetBackup/.ash'`. It is evaluated and piped
# into cryptsetup on stdin so the key never touches disk on the local host.
prepare_luks_mount() {
  local key_cmd="$1"                 # e.g. "ssh nas-core 'cat /volume1/NetBackup/.ash'"
  local crypt_file="$2"              # e.g. /home/Backup_WebApp.crypt
  local mapper_name="$3"             # e.g. Backup_WebApp_crypt
  local mount_point="${4:-$MOUNT_POINT_DEFAULT}"

  local expected_dev="/dev/mapper/${mapper_name}"
  local current_src=""

  mkdir -p "$mount_point" || {
    log_msg "ERROR: cannot create $mount_point"
    return 1
  }

  cleanup_tmp_crypt_and_backup_mappers "$mount_point" || return 1

  log_msg "Opening ${crypt_file} -> ${mapper_name}"
  if ! eval "$key_cmd" | cryptsetup open "$crypt_file" "$mapper_name" --key-file /dev/stdin; then
    log_msg "ERROR: cryptsetup open failed for ${crypt_file} -> ${mapper_name}"
    return 1
  fi

  if ! is_mapper_open "$mapper_name"; then
    log_msg "ERROR: mapper ${mapper_name} not open after cryptsetup open"
    return 1
  fi

  log_msg "Mounting ${expected_dev} on ${mount_point}"
  if ! mount "$expected_dev" "$mount_point"; then
    log_msg "ERROR: mount of ${expected_dev} on ${mount_point} failed"
    if is_mapper_open "$mapper_name"; then
      log_msg "Cleanup: closing ${mapper_name} after failed mount"
      cryptsetup close "$mapper_name" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  if ! mountpoint -q "$mount_point"; then
    log_msg "ERROR: ${mount_point} is not a mountpoint after mount"
    if is_mapper_open "$mapper_name"; then
      cryptsetup close "$mapper_name" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  current_src="$(findmnt -rn -M "$mount_point" -o SOURCE 2>/dev/null || true)"
  if [ "$current_src" != "$expected_dev" ]; then
    log_msg "ERROR: wrong device mounted on ${mount_point}: ${current_src:-unknown} (expected: ${expected_dev})"
    if mountpoint -q "$mount_point"; then
      umount "$mount_point" >/dev/null 2>&1 || true
    fi
    if is_mapper_open "$mapper_name"; then
      cryptsetup close "$mapper_name" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  log_msg "OK: ${expected_dev} mounted on ${mount_point}"
  return 0
}

close_luks_mount() {
  local mapper_name="$1"
  local mount_point="${2:-$MOUNT_POINT_DEFAULT}"
  local current_src=""

  if mountpoint -q "$mount_point"; then
    current_src="$(findmnt -rn -M "$mount_point" -o SOURCE 2>/dev/null || true)"
    log_msg "Current mount on ${mount_point}: ${current_src:-unknown}"
    log_msg "Attempting to unmount ${mount_point}"

    sync
    if ! umount "$mount_point"; then
      log_msg "ERROR: cannot unmount ${mount_point}"
      if command -v fuser >/dev/null 2>&1; then
        log_msg "Processes using ${mount_point}:"
        log_cmd_output fuser -vm "$mount_point" || true
      fi
      return 1
    fi
  fi

  if is_mapper_open "$mapper_name"; then
    log_msg "Closing mapper ${mapper_name}"
    if ! cryptsetup close "$mapper_name"; then
      log_msg "ERROR: cannot close ${mapper_name}"
      return 1
    fi
  fi

  if mountpoint -q "$mount_point"; then
    log_msg "ERROR: ${mount_point} still mounted after close"
    return 1
  fi

  if is_mapper_open "$mapper_name"; then
    log_msg "ERROR: ${mapper_name} still open after close"
    return 1
  fi

  log_msg "OK: ${mapper_name} closed and ${mount_point} unmounted"
  return 0
}

# Post-job assertion: nothing of ours is left in a decrypted state.
# Any backup script should call this at the very end, after any
# error trap has fired. If this fails, alert and exit non-zero.
assert_no_backup_luks_left_open() {
  local mount_point="${1:-$MOUNT_POINT_DEFAULT}"

  if mountpoint -q "$mount_point"; then
    log_msg "ERROR: ${mount_point} still mounted"
    log_cmd_output findmnt -rn -M "$mount_point" -o SOURCE,TARGET,FSTYPE,OPTIONS || true
    return 1
  fi

  if list_open_backup_mappers | grep -q .; then
    log_msg "ERROR: backup mappers still open"
    while IFS= read -r mapper; do
      [ -n "$mapper" ] || continue
      log_msg "Open mapper: $mapper"
    done < <(list_open_backup_mappers)
    return 1
  fi

  log_msg "OK: no backup container open, no mount on ${mount_point}"
  return 0
}
