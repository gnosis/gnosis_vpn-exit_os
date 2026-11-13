#!/usr/bin/env bats
# tests/integration/run.sh checks an installed VM over SSH. Its unprovisioned
# phase expects the installer's enrollment files only on a device built with
# the bastion inputs; a LAN-only device, like the published Incus ISO, has none.

load helpers

RUN="${REPO_ROOT}/tests/integration/run.sh"

setup() {
  setup_sandbox
  DEVICE_ETC="${SANDBOX}/device/etc/gvpn-exit"
  mkdir -p "${DEVICE_ETC}"
  export DEVICE_ETC
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  # A device reached over SSH: commands about the installer's enrollment files
  # and enroll-tunnel.service run against DEVICE_ETC, enroll-tunnel follows its
  # unit's conditions, the connection itself works, everything else fails.
  mock_cmd systemctl '
enrolled() { [[ -e "${DEVICE_ETC}/support.env" && -e "${DEVICE_ETC}/enroll.key" ]]; }
case "$1" in
  show) if enrolled; then printf "active\nyes\n"; else printf "inactive\nno\n"; fi ;;
  is-active) enrolled ;;
  *) exit 1 ;;
esac'
  mock_cmd ssh '
while (( $# )); do
  arg="$1"
  shift
  [[ "${arg}" == devops@* ]] && break
done
cmd="$*"
cmd="${cmd#sudo }"
case "${cmd}" in
  true) exit 0 ;;
  *enroll-tunnel.service*|*/etc/gvpn-exit/*)
    cmd="${cmd//\/etc\/gvpn-exit/${DEVICE_ETC}}"
    eval "${cmd}" ;;
  *) exit 1 ;;
esac'
}

teardown() {
  teardown_sandbox
}

write_enrollment_files() {
  echo "SUPPORT_PORT=22001" >"${DEVICE_ETC}/support.env"
  echo "bastion ssh-ed25519 AAAA" >"${DEVICE_ETC}/bastion_known_hosts"
  echo "key" >"${DEVICE_ETC}/enroll.key"
  chmod 600 "${DEVICE_ETC}/enroll.key"
}

@test "unprovisioned accepts a LAN-only device without enrollment files" {
  run bash "${RUN}" unprovisioned
  [[ "${output}" == *"PASS installer wrote no bastion files"* ]]
  [[ "${output}" == *"PASS enroll-tunnel.service inactive by condition"* ]]
  [[ "${output}" != *"FAIL installer"* ]]
  [[ "${output}" != *"FAIL enroll-tunnel"* ]]
}

@test "unprovisioned flags enrollment files on a device built without a bastion" {
  write_enrollment_files
  run bash "${RUN}" unprovisioned
  [[ "${output}" == *"FAIL installer wrote no bastion files"* ]]
  [[ "${output}" == *"FAIL enroll-tunnel.service inactive by condition"* ]]
}

@test "unprovisioned still requires the enrollment files when the bastion inputs are set" {
  export GVPN_BASTION=ssh://bastion@192.0.2.1:2222
  run bash "${RUN}" unprovisioned
  [[ "${output}" == *"FAIL installer wrote the bastion and port"* ]]
  [[ "${output}" == *"FAIL installer pinned the bastion host key"* ]]
  [[ "${output}" == *"FAIL enroll-tunnel.service running"* ]]
}

# Another rehearsal's device can still hold the reverse port on the bastion;
# answering there is not enough, it has to be the device under test.
@test "enroll requires the device under test behind the bastion port" {
  mock_cmd ssh '
port=""
while (( $# )); do
  arg="$1"
  shift
  [[ "${arg}" == -p ]] && port="$1"
  [[ "${arg}" == devops@* ]] && break
done
case "$*" in
  true) exit 0 ;;
  "cat /etc/machine-id") if [[ "${port}" == 22001 ]]; then echo "${MOCK_TUNNEL_ID}"; else echo device-under-test; fi ;;
  *) exit 1 ;;
esac'
  export VM_BASTION_WAIT=0
  MOCK_TUNNEL_ID=another-device run bash "${RUN}" enroll
  [[ "${output}" == *"FAIL devops reachable through the bastion"* ]]
  MOCK_TUNNEL_ID=device-under-test run bash "${RUN}" enroll
  [[ "${output}" == *"PASS devops reachable through the bastion"* ]]
}
