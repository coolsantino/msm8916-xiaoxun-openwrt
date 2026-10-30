#!/bin/sh
# One-shot Qualcomm firmware dumper: mount partitions read-only,
# copy relevant blobs into /lib/firmware, set a marker to avoid
# re-running, and trigger a reboot. Accepts optional 'MCFG_PATH'
# env var to override the MCFG relative path within modem/persist.

set -e
DEFAULT_FLAG="/lib/firmware/DUMPED"
DEFAULT_MCFG_PATH="image/modem_pr/mcfg/configs/mcfg_sw/generic/common/row/gen_3gpp"

MARKER="${FLAG:-$DEFAULT_FLAG}"
[ -f "$MARKER" ] && exit 0

log() { logger -t msm-fw-dumper "$*"; }
MNT="/tmp/mnt/msmfw"
FW="/lib/firmware"
MCFG_REL="${MCFG_PATH:-$DEFAULT_MCFG_PATH}"

# Resolve a GPT partition by its PARTNAME exported by the kernel in sysfs.
# This avoids assuming that the eMMC is always /dev/mmcblk0 or that its
# partition numbers never change.
find_partition_by_name() {
  wanted="$1"
  found=""

  for uevent in /sys/class/block/*/uevent; do
    [ -r "$uevent" ] || continue

    part_name=$(sed -n 's/^PARTNAME=//p' "$uevent") || continue
    [ "$part_name" = "$wanted" ] || continue

    dev_name=$(sed -n 's/^DEVNAME=//p' "$uevent") || continue
    [ -n "$dev_name" ] || continue

    candidate="/dev/$dev_name"
    [ -b "$candidate" ] || continue

    if [ -n "$found" ]; then
      log "ERROR: multiple block devices have GPT partition name '$wanted'"
      return 1
    fi
    found="$candidate"
  done

  if [ -z "$found" ]; then
    log "ERROR: GPT partition '$wanted' not found in /sys/class/block"
    return 1
  fi

  printf '%s\n' "$found"
}

# Mount a named GPT partition read-only. Failure is reported to the caller,
# which can decide whether to continue without that partition.
mount_partition_by_name() {
  partition_name="$1"
  filesystem="$2"
  mount_options="$3"
  mountpoint="$4"

  if ! device=$(find_partition_by_name "$partition_name"); then
    log "WARN: cannot resolve partition '$partition_name'; skipping mount"
    return 1
  fi

  if mount -t "$filesystem" -o "$mount_options" "$device" "$mountpoint"; then
    log "mounted GPT partition '$partition_name' ($device) at $mountpoint"
    return 0
  fi

  log "WARN: mount failed for GPT partition '$partition_name' ($device)"
  return 1
}

log "start (marker not present)"
# Prepare mount points and target
mkdir -p "$MNT/modem" "$MNT/persist" "$FW/wlan/prima"

# Mount by GPT partition name, not by hard-coded /dev/mmcblk0pN nodes.
mount_partition_by_name modem vfat ro,nosuid,nodev,noexec,iocharset=iso8859-1,codepage=437 "$MNT/modem" || true
mount_partition_by_name persist ext4 ro,nosuid,nodev,noexec "$MNT/persist" || true

# Copy if exists!
copy_if() {
  src="$1"; dst="$2"
  if [ -f "$src" ]; then
    cp -af "$src" "$dst" && log "copied $(basename "$src")" || return $?
  fi
  return 0
}

# Modem/Wi-Fi core blobs (MDT + fragments + MBA if present)
for p in "$MNT/modem"/image/wcnss.mdt "$MNT/modem"/image/wcnss.b* \
         "$MNT/modem"/image/modem.mdt "$MNT/modem"/image/modem.b* \
         "$MNT/modem"/image/mba.mbn
do
  [ -f "$p" ] && cp -af "$p" "$FW/"
done
# Wi-Fi NV/configs required by wcn36xx (place under wlan/prima)
copy_if "$MNT/persist/WCNSS_qcom_wlan_nv.bin" "$FW/wlan/prima/WCNSS_qcom_wlan_nv.bin"
copy_if "$MNT/modem/image/wlan/prima/WCNSS_qcom_wlan_nv.bin" "$FW/wlan/prima/WCNSS_qcom_wlan_nv.bin"
copy_if "$MNT/modem/image/wlan/prima/WCNSS_cfg.dat" "$FW/wlan/prima/WCNSS_cfg.dat"
copy_if "$MNT/modem/image/wlan/prima/WCNSS_qcom_cfg.ini" "$FW/wlan/prima/WCNSS_qcom_cfg.ini"
# MCFG handling:
if [ -f "$MNT/modem/$MCFG_REL/mcfg_sw.mbn" ]; then
  cp -af "$MNT/modem/$MCFG_REL/mcfg_sw.mbn" "$FW/MCFG_SW.MBN" && log "MCFG from modem:$MCFG_REL"
else
  log "WARN: MCFG 'MCFG_PATH=$MCFG_REL' not found in modem"
fi

# Honoring any user copied MCFG to /lib/firmware
[ -f "$FW/mcfg_sw.mbn" ] && ln -sf "$FW/mcfg_sw.mbn" "$FW/MCFG_SW.MBN" 2>/dev/null || true

sync
# Unmount and cleanup
umount "$MNT/modem" 2>/dev/null || true
umount "$MNT/persist" 2>/dev/null || true
rmdir "$MNT/persist" "$MNT/modem" 2>/dev/null || true

# Set marker and reboot once
touch "$MARKER"
log "Dumped!"

exit 0
