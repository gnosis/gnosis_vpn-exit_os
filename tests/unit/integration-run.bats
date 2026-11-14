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
  [[ "${arg}" == gvpn@* ]] && break
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
  [[ "${arg}" == gvpn@* ]] && break
done
case "$*" in
  true) exit 0 ;;
  "cat /etc/machine-id") if [[ "${port}" == 22001 ]]; then echo "${MOCK_TUNNEL_ID}"; else echo device-under-test; fi ;;
  *) exit 1 ;;
esac'
  export VM_BASTION_WAIT=0
  MOCK_TUNNEL_ID=another-device run bash "${RUN}" enroll
  [[ "${output}" == *"FAIL gvpn reachable through the bastion"* ]]
  MOCK_TUNNEL_ID=device-under-test run bash "${RUN}" enroll
  [[ "${output}" == *"PASS gvpn reachable through the bastion"* ]]
}

# The device's journal, as the AVC check reads it: the device runs no auditd,
# so the journal's audit transport is its audit log, while the kernel log
# carries only a rate-limited copy of some audit records. Root scripts that
# read the journal run here against this model; every other command fails.
device_journal() {
  JOURNAL_DIR="${SANDBOX}/journal"
  mkdir -p "${JOURNAL_DIR}"
  : >"${JOURNAL_DIR}/kernel"
  : >"${JOURNAL_DIR}/audit"
  export JOURNAL_DIR
  mock_cmd ssh '
while (( $# )); do
  arg="$1"
  shift
  [[ "${arg}" == gvpn@* ]] && break
done
case "$*" in
  true) exit 0 ;;
  "sudo bash -c "*journalctl*) eval "${*#sudo }" ;;
  *) exit 1 ;;
esac'
  mock_cmd journalctl '
transports=() pattern="" lines=""
while (( $# )); do
  case "$1" in
    -k|--dmesg) transports+=(kernel) ;;
    _TRANSPORT=*) transports+=("${1#_TRANSPORT=}") ;;
    -g|--grep) pattern="$2"; shift ;;
    -n|--lines) lines="$2"; shift ;;
  esac
  shift
done
(( ${#transports[@]} )) || transports=(kernel audit)
entries="$(cd "${JOURNAL_DIR}" && cat "${transports[@]}")"
if [[ -n "${pattern}" ]]; then
  entries="$(grep -E -- "${pattern}" <<<"${entries}")" || exit 1
fi
[[ -z "${lines}" ]] || entries="$(tail -n "${lines}" <<<"${entries}")"
[[ -z "${entries}" ]] || printf "%s\n" "${entries}"'
}

SERVICE_START='Nov 14 20:58:30 gvpn-exit audit[1]: SERVICE_START pid=1 uid=0 auid=4294967295 ses=4294967295 subj=system_u:system_r:init_t:s0 msg='"'"'unit=chronyd comm="systemd" exe="/usr/lib/systemd/systemd" hostname=? addr=? terminal=? res=success'"'"''
# bootc probes for mac_admin with a label the policy does not know whenever a
# service runs it (recorded on the device).
BOOTC_PROBE='Nov 14 20:58:30 gvpn-exit audit[843]: AVC avc:  denied  { mac_admin } for  pid=843 comm="chcon" capability=33  scontext=system_u:system_r:unconfined_service_t:s0 tcontext=system_u:system_r:unconfined_service_t:s0 tclass=capability2 permissive=0'
SSHD_DENIAL='Nov 14 20:58:31 gvpn-exit audit[1114]: AVC avc:  denied  { read } for  pid=1114 comm="sshd" name="10-listen.conf" dev="tmpfs" ino=42 scontext=system_u:system_r:sshd_t:s0-s0:c0.c1023 tcontext=system_u:object_r:var_run_t:s0 tclass=file permissive=0'

@test "the AVC check reads denials from the audit log, not only the kernel log" {
  device_journal
  printf '%s\n' "${SERVICE_START}" "${BOOTC_PROBE}" "${SSHD_DENIAL}" >"${JOURNAL_DIR}/audit"
  run bash "${RUN}" unprovisioned
  [[ "${output}" == *"FAIL no AVC denials this boot"* ]]
  [[ "${output}" == *'comm="sshd"'* ]]
}

@test "the AVC check accepts bootc's mac_admin probe as the audit log records it" {
  device_journal
  printf '%s\n' "${SERVICE_START}" "${BOOTC_PROBE}" "${BOOTC_PROBE/843/954}" >"${JOURNAL_DIR}/audit"
  run bash "${RUN}" unprovisioned
  [[ "${output}" == *"PASS no AVC denials this boot"* ]]
}

# A journal that receives no audit records would pass the check unread.
@test "the AVC check fails when the journal holds no audit records" {
  device_journal
  run bash "${RUN}" unprovisioned
  [[ "${output}" == *"FAIL no AVC denials this boot"* ]]
  [[ "${output}" == *"no audit records"* ]]
}
