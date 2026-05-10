#!/bin/ash
# ----------------------------------------------------------------------------
# nodes/nas-core/mv2usb.sh - daily mirror of selected datasets to USB
# ----------------------------------------------------------------------------
# Runs on the Synology NAS (DSM 7.3.x, ash shell, NOT bash).
# Mirrors a curated set of consolidated datasets to a detachable USB drive
# attached to the NAS.
#
# Why this exists: the NAS is the single point that aggregates every
# encrypted backup (cross-site rsync targets land here decrypted, by design).
# A weekly USB rotation gives us:
#   * an air-gapped copy that survives a ransomware event reaching the LAN
#   * an offline copy that can be physically removed and stored elsewhere
#
# Operational practice: two USB drives in rotation, one on-site, one off-site.
# Swapped weekly, scrub-tested quarterly.
#
# License: MIT - see LICENSE in the repository root.
# ----------------------------------------------------------------------------

start_time=$(date +%s)
LOG=/var/log/backupUSB.log

echo -e "START : $(date)\n" > "$LOG" 2>&1

mirror_dataset() {
  local label="$1"
  local src="$2"
  local dst="$3"

  echo -e "$label" >&2
  echo -e "\n$label\n" >>"$LOG" 2>&1
  echo -e "\n#####################\n" >>"$LOG" 2>&1
  echo -e "$label =================================================================================================\n" >>"$LOG" 2>&1

  rsync -avxHAWXS \
    --numeric-ids \
    --stats \
    --partial \
    --ignore-errors \
    --human-readable \
    --delete \
    "$src" "$dst" >>"$LOG" 2>&1
}

# ---- Datasets mirrored to USB ----
# (Path layout reflects the production NAS; adjust to your own.)
mirror_dataset "Applis"    "/volume1/Applis/"    "/volumeUSB1/usbshare/volume1/Applis/"
mirror_dataset "WebApp"    "/volume1/WebApp/"    "/volumeUSB1/usbshare/volume1/WebApp/"
mirror_dataset "NetBackup" "/volume1/NetBackup/" "/volumeUSB1/usbshare/volume1/NetBackup/"
mirror_dataset "web"       "/volume1/web/"       "/volumeUSB1/usbshare/volume1/web/"
mirror_dataset "MX2"       "/volume1/MX2/"       "/volumeUSB1/usbshare/volume1/MX2/"
mirror_dataset "Mail"      "/volume1/Mail/"      "/volumeUSB1/usbshare/volume1/Mail/"
mirror_dataset "WebMail"   "/volume1/WebMail/"   "/volumeUSB1/usbshare/volume1/WebMail/"

end_time=$(date +%s)
time_elapsed=$(( (end_time - start_time) / 60 ))
echo -e "\nFINISH : $(date)\n\n" >>"$LOG" 2>&1
echo "Script execution took $time_elapsed minutes." >>"$LOG" 2>&1
