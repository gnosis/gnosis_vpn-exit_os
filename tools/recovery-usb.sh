#!/usr/bin/env bash
# Write the recovery stick for any appliance (docs/recovery.md).
#
#   tools/recovery-usb.sh DEVICE [KEYS_FILE]
#
# DEVICE is a whole USB disk such as /dev/sdX, or any /dev/disk/by-id path to
# one; every byte on it is lost. KEYS_FILE defaults to
# output/recovery/authorized_keys: a plain OpenSSH authorized_keys file whose
# public key lines are the ones the stick grants (docs/recovery.md). Needs
# root.
#
# The stick carries one FAT32 ESP: the Unified Kernel Image at the removable
# media path and the public keys as plain text. Nothing on it is secret; the
# private halves stay on the operators' keys and YubiKeys.
#
# GVPN_RECOVERY_OUTPUT overrides output/recovery, where the image, its
# SHA256SUMS and the default KEYS_FILE live (tests).
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
out_dir="${GVPN_RECOVERY_OUTPUT:-${repo}/output/recovery}"
image="${out_dir}/BOOTX64.EFI"
sums="${out_dir}/SHA256SUMS"
label="GVPNRECOV"
esp_type="C12A7328-F81F-11D2-BA4C-00105AA9B6EC"
key_types='^(ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa) '

die() {
  echo "$*" >&2
  exit 1
}

# require_tool NAME...
# The recipe hands root the caller's PATH so the devshell's tools are found.
# Refuse a tool that resolves somewhere the caller could have planted it: the
# working tree, or a directory group or others can write.
require_tool() {
  local name path dir mode
  for name in "$@"; do
    path="$(command -v "${name}" 2>/dev/null)" || die "${name} is not on PATH"
    [[ -x "${path}" ]] || die "${name} at ${path} is not executable"
    case "$(readlink -f "${path}")" in
      "${repo}"/*) die "${name} resolves into ${repo}; use a system or devshell ${name}" ;;
    esac
    # The directory may itself be a symlink (on NixOS mount and umount resolve
    # into /run/wrappers/bin, a link to a root-owned directory), so judge where
    # it points: a link's own mode is always 0777.
    dir="$(readlink -f "$(dirname "${path}")")"
    mode="$(stat -c %a "${dir}")"
    if (( 8#${mode} & 8#022 )); then
      die "${name} resolves into ${dir}, which group or others can write"
    fi
  done
}

# The external commands the run executes as root, and the ones it uses only
# when the host has them. Every one is resolved from the caller's PATH and
# vetted before the wipe runs it. The three the vetting itself needs come first;
# they are not covered by that guarantee, because require_tool runs readlink,
# dirname and stat to check every name, and dirname already ran before the
# vetting to locate the repository: those three are only as good as the PATH the
# caller handed over.
root_tools=(readlink dirname stat id lsblk awk head grep mktemp sleep wipefs
  sgdisk mkfs.vfat mount umount install sha256sum rmdir sync cut)
optional_root_tools=(partprobe blockdev)

require_root_tools() {
  local optional
  require_tool "${root_tools[@]}"
  for optional in "${optional_root_tools[@]}"; do
    if command -v "${optional}" >/dev/null; then
      require_tool "${optional}"
    fi
  done
}

# The stick is booted on an appliance and this script wipes what it
# is given, so only an unmounted USB disk qualifies: never the build host's
# NVMe or SATA disks, never a stick that is in use.
check_target() {
  local device="$1" transport mounted
  transport="$(lsblk -dno TRAN "${device}")"
  [[ "${transport}" == usb ]] || die "${device} is not a USB disk (transport: ${transport:-none})"
  mounted="$(lsblk -nro MOUNTPOINT "${device}" | awk 'NF' | head -n1)"
  [[ -z "${mounted}" ]] || die "${device} is in use: mounted at ${mounted}; unmount it first"
}

check_image() {
  [[ -f "${image}" ]] || die "${image} is missing; run: just recovery-build"
  [[ -f "${sums}" ]] || die "${sums} is missing; rebuild the image with: just recovery-build"
  (cd "${out_dir}" && sha256sum -c SHA256SUMS >/dev/null 2>&1) ||
    die "the image does not match SHA256SUMS; rebuild it with: just recovery-build"
}

check_keys() {
  [[ -f "$1" ]] || die "$1 is missing; write the operators' public keys into it"
  grep -qE "${key_types}" "$1" || die "$1 carries no public key"
}

# partition_node DEVICE
# The first partition's node for a whole disk: sdz -> sdz1, but nvme0n1 and
# mmcblk0 get a p (nvme0n1p1).
partition_node() {
  local device="$1"
  if [[ "${device}" =~ [0-9]$ ]]; then
    printf '%sp1\n' "${device}"
  else
    printf '%s1\n' "${device}"
  fi
}

# wait_for_partition DEVICE PARTITION
# The kernel creates the partition node asynchronously (and a USB stick's
# partition table is re-read only when the device is not busy), so wait for it
# instead of racing mkfs.
wait_for_partition() {
  local device="$1" partition="$2" tries=40
  while ((tries > 0)); do
    [[ -b "${partition}" ]] && return 0
    if command -v partprobe >/dev/null; then
      partprobe "${device}" 2>/dev/null || true
    fi
    command -v blockdev >/dev/null && blockdev --rereadpt "${device}" 2>/dev/null || true
    sleep 0.25
    tries=$((tries - 1))
  done
  return 1
}

main() {
  local device="${1:-}" keys="${2:-${out_dir}/authorized_keys}" partition mnt

  [[ -n "${device}" ]] || die "usage: ${0} DEVICE [KEYS_FILE]"
  [[ -b "${device}" ]] || die "${device} is not a block device"
  require_root_tools
  [[ "$(id -u)" -eq 0 ]] || die "run this as root: sudo ${0} ${device}"
  check_target "${device}"
  check_image
  check_keys "${keys}"

  # /dev/disk/by-id and /dev/disk/by-path name the same disk, but the partition
  # node is only named for the kernel device (sda1, nvme0n1p1), so resolve the
  # symlink before deriving it.
  device="$(readlink -f "${device}")"
  partition="$(partition_node "${device}")"

  # wipefs also clears signatures sgdisk leaves behind, such as the ISO 9660
  # volume of a stick that last carried the installer, which wipes NVMe.
  wipefs -a "${device}"
  sgdisk --zap-all "${device}"
  sgdisk --new=1:0:+512M --typecode="1:${esp_type}" --change-name="1:${label}" "${device}"

  wait_for_partition "${device}" "${partition}" || die "${partition} did not appear; replug the stick and try again"
  mkfs.vfat -F 32 -n "${label}" "${partition}"

  mnt="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand mnt now; it is local to main
  trap "umount '${mnt}' 2>/dev/null || true; rmdir '${mnt}' 2>/dev/null || true" EXIT
  mount "${partition}" "${mnt}"
  install -D -m 0644 "${image}" "${mnt}/EFI/BOOT/BOOTX64.EFI"
  install -D -m 0644 "${keys}" "${mnt}/gvpn-recovery/authorized_keys"
  # The recovery run writes its report next to the keys.
  sync
  umount "${mnt}"
  trap - EXIT
  rmdir "${mnt}"
  sync

  printf 'recovery stick written to %s\n' "${device}"
  printf 'image: %s\n' "$(sha256sum "${image}" | cut -d' ' -f1)"
  printf 'keys:  %s\n' "$(grep -cE "${key_types}" "${keys}")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
