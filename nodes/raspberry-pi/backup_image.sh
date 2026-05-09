#!/bin/bash
# ----------------------------------------------------------------------------
# nodes/raspberry-pi/backup_image.sh — RPi root image to remote storage
# ----------------------------------------------------------------------------
# Runs on each Raspberry Pi node (RaspiOS) via cron. Mounts the offsite
# backup share (sshfs to mx-secondary), produces a compact image of the
# running root using RonR's image-backup utility, and unmounts cleanly.
#
# RonR-RPi-image-utils:
#   https://github.com/RonR-RPi/RonR-RPi-image-utils
# It supports incremental image updates: re-running over the same .img
# file only writes the changed blocks, which is what makes daily
# image-level backups affordable on a small Pi.
#
# IMPORTANT: as of this writing, the destination images on mx-secondary
# are stored *in cleartext*. See extras/rpi-image-luks-wrapper.sh for the
# planned migration to LUKS-encrypted storage.
#
# License: MIT — see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

LOG=/root/_log.log
MOUNT_POINT=/mnt/RpiBackup
REMOTE_HOST="${REMOTE_HOST:-mx-secondary.example.org}"
REMOTE_PORT="${REMOTE_PORT:-1622}"
REMOTE_PATH="${REMOTE_PATH:-/home/RpiBackup}"
IMG_NAME="${IMG_NAME:-RpiBackup.img}"
REMOTE_LOG_PATH="${REMOTE_LOG_PATH:-/var/log/08_backupMX2_RpiBackup.log}"

echo "begin: $(date)" >> "$LOG" 2>&1

# Defensive cleanup in case a previous run was interrupted with the share
# still mounted (it happens — power cuts, sshfs deadlocks).
mountpoint -q "$MOUNT_POINT" && /usr/bin/umount "$MOUNT_POINT" >/dev/null 2>&1 || true
mkdir -p "$MOUNT_POINT"

# Mount the offsite backup target.
/usr/bin/sshfs \
  -o ssh_command="ssh -T -o RequestTTY=no" \
  -p "$REMOTE_PORT" \
  "${REMOTE_HOST}:${REMOTE_PATH}" "$MOUNT_POINT"

# Run image-backup in the background so we can wait on it explicitly.
# RonR's tool writes incremental blocks, so daily runs over the same
# image complete in minutes once the initial full has been taken.
/usr/local/sbin/image-backup "${MOUNT_POINT}/${IMG_NAME}" &
PID=$!
wait "$PID"

# Buffer flush + tear-down. fusermount is the right tool for sshfs.
sleep 10
/bin/fusermount -u "$MOUNT_POINT"

echo "end: $(date)" >> "$LOG" 2>&1

# Notify the receiving host that we just landed a fresh image, so the
# orchestrator's log scan picks it up alongside the other jobs.
ssh "$REMOTE_HOST" -p "$REMOTE_PORT" \
  -T -q -o RequestTTY=no -o LogLevel=ERROR \
  "echo \"\$(date)\" >> \"$REMOTE_LOG_PATH\" 2>&1"
