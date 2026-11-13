#!/usr/bin/env bash
# Write the installer ISO to a whole USB disk (docs/first-install.md).
#
#   tools/write-usb.sh DEVICE
#
# DEVICE is the whole disk, not a partition, and any path to it will do. It
# must be on USB and have no mounted partition: this wipes every byte, and the
# ISO installs an appliance whose disk it erases without asking.
#
#   GVPN_ISO  the image to write (default output/iso/bootiso/install.iso)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${GVPN_ISO:-${repo}/output/iso/bootiso/install.iso}"

die() {
  echo "$*" >&2
  exit 1
}

main() {
  local device transport mounted
  [[ -n "${1:-}" ]] || die "usage: ${0} DEVICE"
  [[ -f "${ISO}" ]] || die "${ISO} is missing; build it with: just iso"
  device="$(readlink -f "$1")"
  [[ -n "${device}" ]] || die "$1 does not resolve to a device"
  [[ "$(lsblk -dno TYPE "${device}" 2>/dev/null)" == disk ]] \
    || die "${device} is not a whole disk (give the disk, not a partition)"
  transport="$(lsblk -dno TRAN "${device}" 2>/dev/null)"
  [[ "${transport}" == usb ]] || die "${device} is not a USB disk (transport: ${transport:-none})"
  mounted="$(lsblk -nro MOUNTPOINT "${device}" | awk 'NF' | head -n1)"
  [[ -z "${mounted}" ]] || die "${device} is in use: mounted at ${mounted}; unmount it first"

  exec sudo dd if="${ISO}" of="${device}" bs=4M conv=fsync status=progress
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
