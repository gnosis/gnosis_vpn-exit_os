#!/usr/bin/env bats
# recovery-usb.sh wipes the disk it is given, so it refuses anything that is
# not an unmounted USB disk, and an image that does not match the SHA256SUMS
# the build wrote next to it.

load helpers

USB="${REPO_ROOT}/tools/recovery-usb.sh"

setup() {
  setup_sandbox
  export GVPN_RECOVERY_OUTPUT="${SANDBOX}/out"
  mkdir -p "${GVPN_RECOVERY_OUTPUT}"
  echo 'uki' >"${GVPN_RECOVERY_OUTPUT}/BOOTX64.EFI"
  (cd "${GVPN_RECOVERY_OUTPUT}" && sha256sum BOOTX64.EFI >SHA256SUMS)
}

teardown() {
  teardown_sandbox
}

# disk TRANSPORT [MOUNTPOINT]
disk() {
  mock_cmd lsblk "case \"\$*\" in
    *TRAN*) echo $1 ;;
    *MOUNTPOINT*) printf '\n%s\n' '${2:-}' ;;
  esac"
}

@test "an unmounted USB disk is accepted" {
  disk usb
  run in_script "${USB}" check_target /dev/sdz
  [ "${status}" -eq 0 ]
}

@test "a disk that is not on USB is refused" {
  disk nvme
  run in_script "${USB}" check_target /dev/nvme0n1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a USB disk"* ]]
}

@test "a USB disk with a mounted partition is refused" {
  disk usb /run/media/ops/STICK
  run in_script "${USB}" check_target /dev/sdz
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"/run/media/ops/STICK"* ]]
}

# /dev/disk/by-id/... is a symlink to the kernel device; deriving the partition
# from the symlink name produced <link>p1, which never appears after the wipe.
@test "the partition node is derived from the kernel device name" {
  [ "$(in_script "${USB}" partition_node /dev/sdz)" = "/dev/sdz1" ]
  [ "$(in_script "${USB}" partition_node /dev/nvme0n1)" = "/dev/nvme0n1p1" ]
  [ "$(in_script "${USB}" partition_node /dev/mmcblk0)" = "/dev/mmcblk0p1" ]
}

# Root runs these from the caller's PATH, so a tool planted in the working tree
# or a writable directory must be refused.
@test "a tool resolved from a writable directory is refused" {
  mkdir -p "${SANDBOX}/bin2"
  chmod 0777 "${SANDBOX}/bin2"
  printf '#!/bin/sh\nexit 0\n' > "${SANDBOX}/bin2/wipefs"
  chmod +x "${SANDBOX}/bin2/wipefs"
  PATH="${SANDBOX}/bin2:${PATH}"
  run in_script "${USB}" require_tool wipefs
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"group or others can write"* ]]
}

# The directory a tool sits in may itself be a symlink: on NixOS mount and
# umount resolve into /run/wrappers/bin, a link in a root-owned directory that
# points at a root-owned one. A link's own mode is 0777, so the target decides.
@test "a tool reached through a symlinked directory is accepted" {
  mkdir -p "${SANDBOX}/root-owned" "${SANDBOX}/links"
  chmod 0755 "${SANDBOX}/root-owned"
  ln -s "${SANDBOX}/root-owned" "${SANDBOX}/links/bin"
  printf '#!/bin/sh\nexit 0\n' > "${SANDBOX}/root-owned/wipefs"
  chmod +x "${SANDBOX}/root-owned/wipefs"
  PATH="${SANDBOX}/links/bin:${PATH}"
  run in_script "${USB}" require_tool wipefs
  [ "${status}" -eq 0 ]
}

@test "a tool reached through a symlink into a writable directory is refused" {
  mkdir -p "${SANDBOX}/bin2" "${SANDBOX}/links"
  chmod 0777 "${SANDBOX}/bin2"
  ln -s "${SANDBOX}/bin2" "${SANDBOX}/links/bin"
  printf '#!/bin/sh\nexit 0\n' > "${SANDBOX}/bin2/wipefs"
  chmod +x "${SANDBOX}/bin2/wipefs"
  PATH="${SANDBOX}/links/bin:${PATH}"
  run in_script "${USB}" require_tool wipefs
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"group or others can write"* ]]
}

@test "a missing tool is named" {
  run in_script "${USB}" require_tool hopr-not-a-tool
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"hopr-not-a-tool is not on PATH"* ]]
}

# Root runs every command of the run from the caller's PATH, not only the ones
# the wipe itself calls. A fake that delegates to the real tool is planted for
# each listed command in turn, so the vetting gets as far as the directory the
# command resolves into and has to refuse and name it. A host without the tool
# (the unit suites run on Darwin, where lsblk, wipefs or a Linux mount may be
# missing) cannot exercise it: the vetting's own "is not on PATH" refusal covers
# it. The test fails only when no tool at all could be exercised.
@test "every listed root command is refused where the caller could have planted it" {
  local tool real exercised=0
  local -a tools
  run bash -c 'source "$1"; printf "%s\n" "${root_tools[@]}"' _ "${USB}"
  [ "${status}" -eq 0 ]
  tools=(${output})
  (( ${#tools[@]} > 0 ))
  mkdir -p "${SANDBOX}/bin2"
  chmod 0777 "${SANDBOX}/bin2"
  for tool in "${tools[@]}"; do
    real="$(type -P "${tool}" || true)"
    [[ -n "${real}" ]] || continue
    printf '#!/bin/sh\nexec %s "$@"\n' "${real}" > "${SANDBOX}/bin2/${tool}"
    chmod +x "${SANDBOX}/bin2/${tool}"
    run env PATH="${SANDBOX}/bin2:${PATH}" bash -c 'source "$1"; require_root_tools' _ "${USB}"
    rm -f "${SANDBOX}/bin2/${tool}"
    # The vetting stops at the first tool this host lacks, so a planted tool
    # after that one cannot be reached.
    if [[ "${output}" == *" is not on PATH"* ]]; then
      continue
    fi
    [ "${status}" -ne 0 ] || { echo "${tool} was not vetted"; false; }
    [[ "${output}" == *"${tool}"*"group or others can write"* ]] \
      || { echo "${tool} was refused without naming it: ${output}"; false; }
    exercised=$((exercised + 1))
  done
  (( exercised > 0 )) || { echo "no listed root tool could be exercised on this host"; false; }
}

@test "a planted tool the run calls as root is refused" {
  mkdir -p "${SANDBOX}/bin2"
  chmod 0777 "${SANDBOX}/bin2"
  printf '#!/bin/sh\nexit 0\n' > "${SANDBOX}/bin2/lsblk"
  chmod +x "${SANDBOX}/bin2/lsblk"
  PATH="${SANDBOX}/bin2:${PATH}"
  run in_script "${USB}" require_root_tools
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"lsblk"*"group or others can write"* ]]
}

# The exclusion is the repository, not whatever directory the caller happens to
# be in: the recipe may run from anywhere.
@test "a tool resolved inside the repository is refused from another directory" {
  local physical
  mkdir -p "${SANDBOX}/repo/tools" "${SANDBOX}/repo/bin" "${SANDBOX}/elsewhere"
  cp "${USB}" "${SANDBOX}/repo/tools/recovery-usb.sh"
  printf '#!/bin/sh\nexit 0\n' > "${SANDBOX}/repo/bin/lsblk"
  chmod +x "${SANDBOX}/repo/bin/lsblk"
  PATH="${SANDBOX}/repo/bin:${PATH}"
  cd "${SANDBOX}/elsewhere"
  physical="$(cd "${SANDBOX}/repo" && pwd -P)"
  run in_script "${SANDBOX}/repo/tools/recovery-usb.sh" require_tool lsblk
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"resolves into ${physical}"* ]]
}

# A key an operator is told to use must work on the stick, in the recovery run
# and in the installer: the three lists of accepted key types have to agree.
@test "the stick, the recovery run and the installer accept the same key types" {
  local type
  for type in ssh-ed25519 sk-ssh-ed25519@openssh.com ecdsa-sha2-nistp256 \
      sk-ecdsa-sha2-nistp256@openssh.com ssh-rsa; do
    grep -q -- "${type}" "${USB}" || { echo "${USB} lacks ${type}"; false; }
    grep -q -- "${type}" "${REPO_ROOT}/image/recovery/gvpn-recovery.sh" \
      || { echo "gvpn-recovery.sh lacks ${type}"; false; }
    grep -q -- "${type}" "${REPO_ROOT}/tools/render-bib-config.sh" \
      || { echo "render-bib-config.sh lacks ${type}"; false; }
  done
}

@test "a matching image is accepted" {
  run in_script "${USB}" check_image
  [ "${status}" -eq 0 ]
}

@test "an image without SHA256SUMS is refused" {
  rm "${GVPN_RECOVERY_OUTPUT}/SHA256SUMS"
  run in_script "${USB}" check_image
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"SHA256SUMS"* ]]
}

@test "an image that does not match SHA256SUMS is refused" {
  echo 'tampered' >"${GVPN_RECOVERY_OUTPUT}/BOOTX64.EFI"
  run in_script "${USB}" check_image
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not match SHA256SUMS"* ]]
}
