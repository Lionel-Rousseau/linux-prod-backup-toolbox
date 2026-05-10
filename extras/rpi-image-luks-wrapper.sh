#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# extras/rpi-image-luks-wrapper.sh
# ----------------------------------------------------------------------------
# Wraps the cleartext RPi image storage on mx-secondary in a LUKS volume,
# closing the only known confidentiality gap in the current backup chain.
#
# This runs on mx-secondary (the OVH-hosted server that receives and
# stores Pi images). CPU overhead from LUKS is negligible on a server-class
# host. The Raspberry Pi clients do not deal with encryption as they see
# only a plain sshfs mountpoint.
#
# Approach:
#   1. A single LUKS container file (sized to fit your retention).
#   2. Container is opened on demand: just before each Pi pushes its
#      image, opened from a key fetched over SSH from nas-home or locally.
#   3. Container is closed immediately after the last Pi finishes.
#      The LUKS device is never mounted longer than needed.
#
# Operational mode is split in two parts:
#   - "init"     : one-time creation of the LUKS container
#   - "open"     : open + mount, used at the start of an evening's run
#   - "close"    : unmount + close, used at the end
#
# Usage:
#   rpi-image-luks-wrapper.sh init  --container /home/RpiBackup.crypt --size 32G
#   rpi-image-luks-wrapper.sh open  --container /home/RpiBackup.crypt --mapper RpiBackup_crypt --mountpoint /home/RpiBackup
#   rpi-image-luks-wrapper.sh close --mapper RpiBackup_crypt --mountpoint /home/RpiBackup
#
# License: MIT — see LICENSE in the repository root.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  init    Create the LUKS container file. ONE-TIME operation.
  open    Open and mount the LUKS container.
  close   Unmount and close the LUKS container.

Common options:
  --container <PATH>     LUKS container file path (e.g. /home/RpiBackup.crypt)
  --mapper <NAME>        dm-crypt mapper name (e.g. RpiBackup_crypt)
  --mountpoint <PATH>    where to mount the opened container

init-only:
  --size <SIZE>          size of the container file (e.g. 32G), passed to fallocate
  --key-cmd <CMD>        shell command that prints the new LUKS key on stdout
                         (default: prompts interactively)

open-only:
  --key-cmd <CMD>        shell command that prints the LUKS key on stdout
                         (default: ssh nas-home 'cat /volume1/NetBackup/.ash')

  -h, --help             show this help

Example workflow (one-time):
  $(basename "$0") init  --container /home/RpiBackup.crypt --size 32G
  # follow prompts to set the initial passphrase / key

Example workflow (nightly):
  $(basename "$0") open  --container /home/RpiBackup.crypt \\
                          --mapper RpiBackup_crypt \\
                          --mountpoint /home/RpiBackup
  # ... receive Pi image pushes ...
  $(basename "$0") close --mapper RpiBackup_crypt --mountpoint /home/RpiBackup
EOF
}

# ---- argument parsing ----
CMD="${1:-}"
shift || true
[ -z "$CMD" ] && { usage >&2; exit 2; }

CONTAINER=""
MAPPER=""
MOUNTPOINT=""
SIZE=""
KEY_CMD="ssh -q -T -o LogLevel=ERROR nas-home 'cat /volume1/NetBackup/.ash'"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)  CONTAINER="$2"; shift 2 ;;
    --mapper)     MAPPER="$2"; shift 2 ;;
    --mountpoint) MOUNTPOINT="$2"; shift 2 ;;
    --size)       SIZE="$2"; shift 2 ;;
    --key-cmd)    KEY_CMD="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- guards ----
need_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "ERROR: this script must run as root" >&2
    exit 1
  fi
}

# ---- subcommands ----

cmd_init() {
  need_root
  [ -z "$CONTAINER" ] && { echo "ERROR: --container is required" >&2; exit 2; }
  [ -z "$SIZE" ]      && { echo "ERROR: --size is required" >&2; exit 2; }

  if [ -e "$CONTAINER" ]; then
    echo "ERROR: $CONTAINER already exists; refusing to clobber. Move or remove it first." >&2
    exit 1
  fi

  echo "[init] Allocating sparse file: $CONTAINER ($SIZE) ..."
  # fallocate is fast and creates a sparse file. On filesystems that
  # do not support fallocate (some FUSE mounts), fall back to dd.
  if ! fallocate -l "$SIZE" "$CONTAINER" 2>/dev/null; then
    echo "[init] fallocate failed, falling back to dd ..."
    # convert e.g. 100G to MiB count
    case "$SIZE" in
      *G) count=$(( ${SIZE%G} * 1024 )) ;;
      *M) count=${SIZE%M} ;;
      *)  echo "ERROR: --size must be in M or G" >&2; exit 2 ;;
    esac
    dd if=/dev/zero of="$CONTAINER" bs=1M count="$count" status=progress
  fi
  chmod 0600 "$CONTAINER"

  echo "[init] Fetching key and formatting LUKS2 container (non-interactive) ..."
  if ! eval "$KEY_CMD" | cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha256 \
    --pbkdf argon2id \
    --key-file /dev/stdin \
    --batch-mode \
    "$CONTAINER"; then
    echo "ERROR: luksFormat failed" >&2
    exit 1
  fi

  # Open once with the same key to run mkfs
  TMP_MAPPER="rpi_init_$$"
  if ! eval "$KEY_CMD" | cryptsetup open "$CONTAINER" "$TMP_MAPPER" \
    --key-file /dev/stdin; then
    echo "ERROR: cryptsetup open failed after luksFormat" >&2
    exit 1
  fi

  echo "[init] Creating ext4 filesystem ..."
  mkfs.ext4 -L RpiBackup -m 1 -O ^has_journal,extent "/dev/mapper/$TMP_MAPPER"

  cryptsetup close "$TMP_MAPPER"

  echo
  echo "[init] DONE. Container created — key slot 0 holds the output of:"
  echo "  $KEY_CMD"
  echo
  echo "  Optional: add a recovery passphrase in case the key holder is"
  echo "  unavailable during an emergency restore:"
  echo "    cryptsetup luksAddKey $CONTAINER"
  echo
  echo "  Use \`$(basename "$0") open --key-cmd \"...\"\` to open it."
}

cmd_open() {
  need_root
  [ -z "$CONTAINER" ]  && { echo "ERROR: --container is required" >&2; exit 2; }
  [ -z "$MAPPER" ]     && { echo "ERROR: --mapper is required" >&2; exit 2; }
  [ -z "$MOUNTPOINT" ] && { echo "ERROR: --mountpoint is required" >&2; exit 2; }

  if [ ! -e "$CONTAINER" ]; then
    echo "ERROR: container $CONTAINER does not exist" >&2
    exit 1
  fi

  mkdir -p "$MOUNTPOINT"

  # If something is already there from a crashed run, clean up first.
  if mountpoint -q "$MOUNTPOINT"; then
    echo "[open] $MOUNTPOINT is already mounted, attempting clean unmount first"
    sync
    umount "$MOUNTPOINT" || { echo "ERROR: cannot unmount $MOUNTPOINT" >&2; exit 1; }
  fi
  if cryptsetup status "$MAPPER" >/dev/null 2>&1; then
    echo "[open] $MAPPER is already open, closing first"
    cryptsetup close "$MAPPER" || { echo "ERROR: cannot close stale $MAPPER" >&2; exit 1; }
  fi

  echo "[open] Fetching key and opening container ..."
  if ! eval "$KEY_CMD" | cryptsetup open "$CONTAINER" "$MAPPER" --key-file /dev/stdin; then
    echo "ERROR: cryptsetup open failed" >&2
    exit 1
  fi

  echo "[open] Mounting /dev/mapper/$MAPPER on $MOUNTPOINT ..."
  if ! mount "/dev/mapper/$MAPPER" "$MOUNTPOINT"; then
    echo "ERROR: mount failed; closing $MAPPER for cleanup" >&2
    cryptsetup close "$MAPPER" || true
    exit 1
  fi

  echo "[open] OK: $MOUNTPOINT ready"
}

cmd_close() {
  need_root
  [ -z "$MAPPER" ]     && { echo "ERROR: --mapper is required" >&2; exit 2; }
  [ -z "$MOUNTPOINT" ] && { echo "ERROR: --mountpoint is required" >&2; exit 2; }

  if mountpoint -q "$MOUNTPOINT"; then
    sync
    if ! umount "$MOUNTPOINT"; then
      echo "ERROR: cannot unmount $MOUNTPOINT" >&2
      command -v fuser >/dev/null 2>&1 && fuser -vm "$MOUNTPOINT" || true
      exit 1
    fi
  fi

  if cryptsetup status "$MAPPER" >/dev/null 2>&1; then
    if ! cryptsetup close "$MAPPER"; then
      echo "ERROR: cannot close $MAPPER" >&2
      exit 1
    fi
  fi

  echo "[close] OK: $MAPPER closed, $MOUNTPOINT unmounted"
}

case "$CMD" in
  init)  cmd_init ;;
  open)  cmd_open ;;
  close) cmd_close ;;
  -h|--help) usage ;;
  *)     usage >&2; exit 2 ;;
esac
