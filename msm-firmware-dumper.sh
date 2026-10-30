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

MODEM_MOUNTED=0
PERSIST_MOUNTED=0

# Always release any partition mounted by this script, including on errors.
# A failed extraction must retain its non-zero exit status and must not set
# the DUMPED marker.
cleanup() {
  rc=$?
  trap - 0 HUP INT TERM

  if [ "$PERSIST_MOUNTED" -eq 1 ]; then
    if ! umount "$MNT/persist" >/dev/null 2>&1; then
      log "WARN: failed to unmount persist during cleanup; continuing"
    fi
  fi
  if [ "$MODEM_MOUNTED" -eq 1 ]; then
    if ! umount "$MNT/modem" >/dev/null 2>&1; then
      log "WARN: failed to unmount modem during cleanup; continuing"
    fi
  fi

  rmdir "$MNT/persist" "$MNT/modem" 2>/dev/null || true
  exit "$rc"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

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

# Mount a named GPT partition read-only. Both required partitions must mount;
# callers must not ignore a failure.
mount_partition_by_name() {
  partition_name="$1"
  filesystem="$2"
  mount_options="$3"
  mountpoint="$4"

  if ! device=$(find_partition_by_name "$partition_name"); then
    log "ERROR: cannot resolve required partition '$partition_name'"
    return 1
  fi

  if ! mount -t "$filesystem" -o "$mount_options" "$device" "$mountpoint"; then
    log "ERROR: mount failed for required partition '$partition_name' ($device)"
    return 1
  fi

  log "mounted GPT partition '$partition_name' ($device) at $mountpoint"
  return 0
}

log "start (marker not present)"
mkdir -p "$MNT/modem" "$MNT/persist" "$FW/wlan/prima"

# These partitions are required. Abort on either lookup or mount failure.
if mount_partition_by_name modem vfat ro,nosuid,nodev,noexec,iocharset=iso8859-1,codepage=437 "$MNT/modem"; then
  MODEM_MOUNTED=1
else
  log "ERROR: required modem partition is unavailable; aborting without marker"
  exit 1
fi

if mount_partition_by_name persist ext4 ro,nosuid,nodev,noexec "$MNT/persist"; then
  PERSIST_MOUNTED=1
else
  log "ERROR: required persist partition is unavailable; aborting without marker"
  exit 1
fi

# Copy if exists!
copy_if() {
  src="$1"
  dst="$2"
  if [ -f "$src" ]; then
    cp -af "$src" "$dst" || {
      log "ERROR: failed to copy '$src' to '$dst'"
      return 1
    }
    log "copied $(basename "$src")"
  fi
  return 0
}

# Modem/Wi-Fi core blobs (MDT + fragments + MBA if present)
for p in "$MNT/modem"/image/wcnss.mdt "$MNT/modem"/image/wcnss.b* \
         "$MNT/modem"/image/modem.mdt "$MNT/modem"/image/modem.b* \
         "$MNT/modem"/image/mba.mbn
do
  if [ -f "$p" ]; then
    cp -af "$p" "$FW/" || {
      log "ERROR: failed to copy modem firmware '$p'"
      exit 1
    }
  fi
done

# Wi-Fi NV/configs required by wcn36xx (place under wlan/prima)
copy_if "$MNT/persist/WCNSS_qcom_wlan_nv.bin" "$FW/wlan/prima/WCNSS_qcom_wlan_nv.bin"
copy_if "$MNT/modem/image/wlan/prima/WCNSS_qcom_wlan_nv.bin" "$FW/wlan/prima/WCNSS_qcom_wlan_nv.bin"
copy_if "$MNT/modem/image/wlan/prima/WCNSS_cfg.dat" "$FW/wlan/prima/WCNSS_cfg.dat"
copy_if "$MNT/modem/image/wlan/prima/WCNSS_qcom_cfg.ini" "$FW/wlan/prima/WCNSS_qcom_cfg.ini"

# MCFG handling:
if [ -f "$MNT/modem/$MCFG_REL/mcfg_sw.mbn" ]; then
  cp -af "$MNT/modem/$MCFG_REL/mcfg_sw.mbn" "$FW/MCFG_SW.MBN" || {
    log "ERROR: failed to copy MCFG from modem:$MCFG_REL"
    exit 1
  }
  log "MCFG from modem:$MCFG_REL"
else
  log "WARN: MCFG 'MCFG_PATH=$MCFG_REL' not found in modem"
fi

# Honoring any user copied MCFG to /lib/firmware
[ -f "$FW/mcfg_sw.mbn" ] && ln -sf "$FW/mcfg_sw.mbn" "$FW/MCFG_SW.MBN" 2>/dev/null || true

sync

# Unmount errors are non-fatal: firmware extraction has already completed.
# Log failures, but do not turn an otherwise successful dump into a failure.
if ! umount "$MNT/persist"; then
  log "WARN: failed to unmount persist; continuing"
fi
PERSIST_MOUNTED=0

if ! umount "$MNT/modem"; then
  log "WARN: failed to unmount modem; continuing"
fi
MODEM_MOUNTED=0

# The marker is written only after both required partitions were mounted
# and firmware processing completed. Unmount failures are logged, not fatal.
touch "$MARKER"
log "Dumped!"

exit 0
