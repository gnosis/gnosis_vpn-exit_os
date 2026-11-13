#!/usr/bin/env bash
# tools/write-usb.sh writes the installer ISO to a disk and destroys it, so it
# refuses anything that is not an unmounted whole USB disk.

load helpers

WRITE="${REPO_ROOT}/tools/write-usb.sh"

setup() {
  setup_sandbox
  export GVPN_ISO="${SANDBOX}/install.iso"
  echo 'iso' >"${GVPN_ISO}"
  mock_cmd readlink 'echo /dev/sdz'
  mock_cmd sudo '"$@"'
  mock_cmd dd
}

teardown() {
  teardown_sandbox
}

# disk TYPE TRANSPORT [MOUNTPOINT]
disk() {
  mock_cmd lsblk "case \"\$*\" in
    *TYPE*) echo $1 ;;
    *TRAN*) echo $2 ;;
    *MOUNTPOINT*) printf '\n%s\n' '${3:-}' ;;
  esac"
}

@test "an unmounted whole USB disk is written" {
  disk disk usb
  run "${WRITE}" /dev/disk/by-id/usb-Kingston_DataTraveler-0:0
  [ "${status}" -eq 0 ]
  grep -qx "sudo dd if=${GVPN_ISO} of=/dev/sdz bs=4M conv=fsync status=progress" "${MOCK_LOG}"
}

@test "a partition is refused" {
  disk part usb
  run "${WRITE}" /dev/sdz1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not a whole disk"* ]]
  run grep '^dd ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "a disk that is not on USB is refused" {
  disk disk nvme
  run "${WRITE}" /dev/nvme0n1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not a USB disk"* ]]
  run grep '^dd ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "a disk with a mounted partition is refused" {
  disk disk usb /run/media/ops/INSTALL
  run "${WRITE}" /dev/sdz
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"/run/media/ops/INSTALL"* ]]
  run grep '^dd ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "a missing ISO is named before anything is written" {
  rm "${GVPN_ISO}"
  disk disk usb
  run "${WRITE}" /dev/sdz
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"just iso"* ]]
  run grep -e '^dd ' -e '^sudo ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "the justfile confirms the typed device before calling the writer" {
  mkdir -p "${SANDBOX}/tools"
  cat >"${SANDBOX}/tools/write-usb.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${SANDBOX}/argv"
EOS
  chmod +x "${SANDBOX}/tools/write-usb.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  run bash -c "printf 'wrong\n' | just --justfile '${SANDBOX}/justfile' usb /dev/sdz"
  [ "${status}" -ne 0 ]
  [ ! -e "${SANDBOX}/argv" ]
  run bash -c "printf '/dev/sdz\n' | just --justfile '${SANDBOX}/justfile' usb /dev/sdz"
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/argv")" = "/dev/sdz" ]
}

@test "the justfile names and passes an ISO given as the second argument" {
  mkdir -p "${SANDBOX}/tools"
  cat >"${SANDBOX}/tools/write-usb.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${SANDBOX}/argv"
printf '%s\n' "\${GVPN_ISO:-}" >"${SANDBOX}/iso"
EOS
  chmod +x "${SANDBOX}/tools/write-usb.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  pulled="output/published-iso/install.iso"
  run bash -c "printf '/dev/sdz\n' | just --justfile '${SANDBOX}/justfile' usb /dev/sdz '${pulled}'"
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Writing ${pulled} to "* ]]
  [ "$(cat "${SANDBOX}/argv")" = "/dev/sdz" ]
  [ "$(cat "${SANDBOX}/iso")" = "${pulled}" ]
}

@test "the justfile names the default ISO when none is given" {
  mkdir -p "${SANDBOX}/tools"
  cat >"${SANDBOX}/tools/write-usb.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\${GVPN_ISO-unset}" >"${SANDBOX}/iso"
EOS
  chmod +x "${SANDBOX}/tools/write-usb.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  unset GVPN_ISO
  run bash -c "printf '/dev/sdz\n' | just --justfile '${SANDBOX}/justfile' usb /dev/sdz"
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Writing output/iso/bootiso/install.iso to "* ]]
  [ "$(cat "${SANDBOX}/iso")" = "unset" ]
}

@test "a device name is an argument, not shell source" {
  mkdir -p "${SANDBOX}/tools"
  cat >"${SANDBOX}/tools/write-usb.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${SANDBOX}/argv"
EOS
  chmod +x "${SANDBOX}/tools/write-usb.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  device="/dev/sdz; touch ${SANDBOX}/pwned"
  run bash -c "printf '%s\n' '${device}' | just --justfile '${SANDBOX}/justfile' usb '${device}'"
  [ ! -e "${SANDBOX}/pwned" ]
  [ "$(cat "${SANDBOX}/argv")" = "${device}" ]
}

# The confirmation line prints the device and the ISO; a command substitution
# in either must reach the terminal as text.
@test "the confirmation line prints a device or ISO name without expanding it" {
  mkdir -p "${SANDBOX}/tools"
  cat >"${SANDBOX}/tools/write-usb.sh" <<EOS
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${SANDBOX}/tools/write-usb.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  export USB_DEVICE="/dev/sdz\$(touch ${SANDBOX}/pwned-device)"
  export USB_ISO="install\$(touch ${SANDBOX}/pwned-iso).iso"
  run bash -c 'printf "%s\n" "${USB_DEVICE}" | just --justfile "${SANDBOX}/justfile" usb "${USB_DEVICE}" "${USB_ISO}"'
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Writing ${USB_ISO} to ${USB_DEVICE} - all data on it is lost."* ]]
  [ ! -e "${SANDBOX}/pwned-device" ]
  [ ! -e "${SANDBOX}/pwned-iso" ]
  mock_cmd sudo
  run bash -c 'printf "%s\n" "${USB_DEVICE}" | just --justfile "${SANDBOX}/justfile" recovery-usb "${USB_DEVICE}"'
  echo "${output}"
  [[ "${output}" == *"Writing the recovery stick to ${USB_DEVICE} - all data on it is lost."* ]]
  [ ! -e "${SANDBOX}/pwned-device" ]
}
