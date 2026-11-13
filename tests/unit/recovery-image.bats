#!/usr/bin/env bats
# recovery-image.sh packs the recovery stick into one compressed disk image
# that someone on site writes with balenaEtcher, Rufus or dd. It must carry
# the same layout tools/recovery-usb.sh writes, so the stick boots and the
# recovery script finds its payload by the FAT label.

load helpers

IMAGE_TOOL="${REPO_ROOT}/tools/recovery-image.sh"
NAME="gvpn-recovery-v9.9.9.img.xz"

setup() {
  setup_sandbox
  export GVPN_RECOVERY_OUTPUT="${SANDBOX}/out"
  export GVPN_RECOVERY_VERSION=v9.9.9
  mkdir -p "${GVPN_RECOVERY_OUTPUT}"
  head -c 300000 /dev/urandom >"${GVPN_RECOVERY_OUTPUT}/BOOTX64.EFI"
  (cd "${GVPN_RECOVERY_OUTPUT}" && sha256sum BOOTX64.EFI >SHA256SUMS)
  cat >"${GVPN_RECOVERY_OUTPUT}/authorized_keys" <<'EOF'
# rendered by the bastion inventory
ssh-ed25519 AAAAoperator1 ops@workstation
EOF
}

teardown() {
  teardown_sandbox
}

# The FAT partition of the built image, as a file mtools can read.
partition() {
  local disk="${SANDBOX}/disk.img" start count
  xz -dc "${GVPN_RECOVERY_OUTPUT}/${NAME}" >"${disk}"
  read -r start count < <(sgdisk -i 1 "${disk}" | awk '
    /^First sector:/ { first = $3 } /^Last sector:/ { last = $3 }
    END { print first, last - first + 1 }')
  dd if="${disk}" of="${SANDBOX}/esp.img" bs=512 skip="${start}" count="${count}" 2>/dev/null
  printf '%s\n' "${SANDBOX}/esp.img"
}

@test "the image carries one ESP named like the stick's label" {
  run "${IMAGE_TOOL}"
  [ "${status}" -eq 0 ]
  xz -dc "${GVPN_RECOVERY_OUTPUT}/${NAME}" >"${SANDBOX}/disk.img"
  run sgdisk -i 1 "${SANDBOX}/disk.img"
  [[ "${output}" == *"C12A7328-F81F-11D2-BA4C-00105AA9B6EC"* ]]
  [[ "${output}" == *"Partition name: 'GVPNRECOV'"* ]]
  run sgdisk -i 2 "${SANDBOX}/disk.img"
  [[ "${output}" == *"does not exist"* ]]
}

@test "the ESP is FAT32 labelled GVPNRECOV with the image and keys at their paths" {
  local esp
  "${IMAGE_TOOL}"
  esp="$(partition)"
  minfo -i "${esp}" :: | grep -q 'disk type="FAT32'
  mlabel -s -i "${esp}" :: | grep -qx ' Volume label is GVPNRECOV *'
  mtype -i "${esp}" ::/EFI/BOOT/BOOTX64.EFI | cmp - "${GVPN_RECOVERY_OUTPUT}/BOOTX64.EFI"
  mtype -i "${esp}" ::/gvpn-recovery/authorized_keys | cmp - "${GVPN_RECOVERY_OUTPUT}/authorized_keys"
}

@test "the image ships with a checksum the recipient can verify" {
  run "${IMAGE_TOOL}"
  [ "${status}" -eq 0 ]
  (cd "${GVPN_RECOVERY_OUTPUT}" && sha256sum -c "${NAME}.sha256")
}

@test "a keys file passed as an argument is the one packed" {
  local esp
  echo 'ssh-ed25519 AAAAother ops@laptop' >"${SANDBOX}/keys"
  "${IMAGE_TOOL}" "${SANDBOX}/keys"
  esp="$(partition)"
  mtype -i "${esp}" ::/gvpn-recovery/authorized_keys | grep -q AAAAother
}

@test "an image that does not match SHA256SUMS is refused" {
  echo tampered >>"${GVPN_RECOVERY_OUTPUT}/BOOTX64.EFI"
  run "${IMAGE_TOOL}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not match SHA256SUMS"* ]]
  [ ! -e "${GVPN_RECOVERY_OUTPUT}/${NAME}" ]
}

@test "a keys file without a public key is refused" {
  echo '# nothing here' >"${GVPN_RECOVERY_OUTPUT}/authorized_keys"
  run "${IMAGE_TOOL}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"carries no public key"* ]]
  [ ! -e "${GVPN_RECOVERY_OUTPUT}/${NAME}" ]
}

# The stick carries one keys file, so a second argument is a usage error.
@test "more than one keys file is a usage error" {
  run "${IMAGE_TOOL}" "${SANDBOX}/keys" "${SANDBOX}/more-keys"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"usage:"* ]]
  [ ! -e "${GVPN_RECOVERY_OUTPUT}/${NAME}" ]
}

@test "the recipe takes one optional keys file" {
  mkdir -p "${SANDBOX}/tools"
  cat >"${SANDBOX}/tools/recovery-image.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${SANDBOX}/argv"
EOS
  chmod +x "${SANDBOX}/tools/recovery-image.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"

  run just --justfile "${SANDBOX}/justfile" recovery-image
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/argv")" = "" ]

  run just --justfile "${SANDBOX}/justfile" recovery-image "${SANDBOX}/keys"
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/argv")" = "${SANDBOX}/keys" ]

  run just --justfile "${SANDBOX}/justfile" recovery-image "${SANDBOX}/keys" "${SANDBOX}/keys2"
  [ "${status}" -ne 0 ]
}
