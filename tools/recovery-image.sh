#!/usr/bin/env bash
# Pack the recovery stick into one compressed disk image (docs/recovery.md).
#
#   tools/recovery-image.sh [KEYS_FILE]
#
# The result, output/recovery/gvpn-recovery-<version>.img.xz and its .sha256,
# is what gets sent to someone on site: balenaEtcher, Rufus or
# `xz -dc ... | dd` write it to any USB stick, with no repository and no root.
# It carries the layout tools/recovery-usb.sh writes: one GPT partition of ESP
# type named GVPNRECOV, FAT32 labelled GVPNRECOV, the Unified Kernel Image at
# the removable media path and the public keys next to where the run writes
# its report.
#
# Built in a plain file with sgdisk, mkfs.fat and mtools, so it needs neither
# root nor a loop device and runs on Darwin as well as Linux.
#
# KEYS_FILE defaults to output/recovery/authorized_keys.
#   GVPN_RECOVERY_OUTPUT   overrides output/recovery (tests)
#   GVPN_RECOVERY_VERSION  the name's version (git describe --tags --always --dirty)
set -euo pipefail

# shellcheck source=SCRIPTDIR/recovery-usb.sh
source "$(dirname "${BASH_SOURCE[0]}")/recovery-usb.sh"

# The partition starts at 1 MiB, as sgdisk aligns it on a real stick; the
# disk keeps 1 MiB after it for the backup GPT.
start_sector=2048
esp_mib=512

main() {
  local keys="${1:-${out_dir}/authorized_keys}" version name work disk esp
  # One stick carries one keys file (docs/recovery.md).
  (( $# <= 1 )) || die "usage: ${0} [KEYS_FILE]"
  check_image
  check_keys "${keys}"
  version="${GVPN_RECOVERY_VERSION:-$(git -C "${repo}" describe --tags --always --dirty)}"
  name="gvpn-recovery-${version}.img.xz"

  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand work now; it is local to main
  trap "rm -rf '${work}'" EXIT
  disk="${work}/disk.img"
  esp="${work}/esp.img"

  truncate -s "$((esp_mib + 2))M" "${disk}"
  sgdisk --new="1:${start_sector}:+${esp_mib}M" --typecode="1:${esp_type}" \
    --change-name="1:${label}" "${disk}" >/dev/null

  # -h records where the partition starts, as mkfs.fat does on a real stick.
  mkfs.fat -F 32 -n "${label}" -h "${start_sector}" -C "${esp}" "$((esp_mib * 1024))" >/dev/null
  mmd -i "${esp}" ::/EFI ::/EFI/BOOT ::/gvpn-recovery
  mcopy -i "${esp}" "${image}" ::/EFI/BOOT/BOOTX64.EFI
  mcopy -i "${esp}" "${keys}" ::/gvpn-recovery/authorized_keys
  dd if="${esp}" of="${disk}" bs=512 seek="${start_sector}" conv=notrunc 2>/dev/null

  xz -T0 -c "${disk}" >"${out_dir}/${name}"
  (cd "${out_dir}" && sha256sum "${name}" >"${name}.sha256")

  printf 'recovery image: %s\n' "${out_dir}/${name}"
  printf 'sha256: %s\n' "$(cut -d' ' -f1 "${out_dir}/${name}.sha256")"
  printf 'keys:   %s\n' "$(grep -cE "${key_types}" "${keys}")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
