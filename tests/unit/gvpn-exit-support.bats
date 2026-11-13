#!/usr/bin/env bats
# gvpn-exit-support: the devops CLI that opens, extends and closes the
# time-boxed support tunnel window.

load helpers

NOW=1790220600 # 2026-09-24T03:30:00Z

setup() {
  setup_sandbox
  export GVPN_NOW="${NOW}"
  mock_cmd timedatectl 'echo yes'
  mock_cmd systemctl
  CLI="${ROOTFS}/usr/bin/gvpn-exit-support"
}

teardown() {
  teardown_sandbox
}

@test "extend writes an RFC3339 UTC deadline and starts the tunnel" {
  run "${CLI}" extend 30
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_STATE_DIR}/support-until")" = "2026-10-24T03:30:00Z" ]
  grep -q 'systemctl start support-tunnel.service' "${MOCK_LOG}"
}

@test "extend rejects a non-numeric or out-of-range day count" {
  for days in 0 91 abc -3 ""; do
    run "${CLI}" extend "${days}"
    [ "${status}" -ne 0 ]
  done
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

# A leading zero is not a day count: `010` would be read as octal and `08`
# aborts the arithmetic with a bash error instead of being refused.
@test "extend rejects a day count with a leading zero without an arithmetic error" {
  for days in 08 010; do
    run "${CLI}" extend "${days}"
    [ "${status}" -eq 64 ]
    [[ "${output}" != *"value too great for base"* ]]
    [[ "${output}" == *"days must be an integer"* ]]
  done
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "extend refuses while the clock is not NTP-synchronized" {
  mock_cmd timedatectl 'echo no'
  run "${CLI}" extend 7
  [ "${status}" -ne 0 ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "close removes the window and stops the tunnel" {
  echo "2026-10-24T03:30:00Z" > "${GVPN_STATE_DIR}/support-until"
  run "${CLI}" close
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
  grep -q 'systemctl stop support-tunnel.service' "${MOCK_LOG}"
}

@test "close cancels a pending recovery request, so the timer cannot reopen the window" {
  echo "2026-10-01T03:30:00Z" > "${GVPN_STATE_DIR}/support-until"
  echo 7 > "${GVPN_STATE_DIR}/recovery-request"
  run "${CLI}" close
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
  : > "${MOCK_LOG}"
  run "${LIBEXEC}/support-window.sh" enforce
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
  if grep -q 'systemctl start' "${MOCK_LOG}"; then
    return 1
  fi
}

@test "status reports the deadline" {
  echo "2026-10-24T03:30:00Z" > "${GVPN_STATE_DIR}/support-until"
  run "${CLI}" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2026-10-24T03:30:00Z"* ]]
}

@test "status reports a closed window" {
  run "${CLI}" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"closed"* ]]
}

# The timer (support-window.sh) mutates the same window, so both mutations
# hold one lock: the tunnel is started or stopped only with the window's state
# already settled.
@test "extend holds the support lock while it starts the tunnel" {
  mock_cmd systemctl "if flock -n '${GVPN_RUN_DIR}/support-window.lock' -c true; then echo 'support lock not held' >&2; exit 1; fi"
  run "${CLI}" extend 30
  [ "${status}" -eq 0 ]
  grep -qx 'systemctl start support-tunnel.service' "${MOCK_LOG}"
}

@test "close holds the support lock while it stops the tunnel" {
  echo "2026-10-24T03:30:00Z" > "${GVPN_STATE_DIR}/support-until"
  mock_cmd systemctl "if flock -n '${GVPN_RUN_DIR}/support-window.lock' -c true; then echo 'support lock not held' >&2; exit 1; fi"
  run "${CLI}" close
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
  grep -qx 'systemctl stop support-tunnel.service' "${MOCK_LOG}"
}

@test "close waits for a timer run that holds the lock" {
  echo "2026-10-24T03:30:00Z" > "${GVPN_STATE_DIR}/support-until"
  echo 7 > "${GVPN_STATE_DIR}/recovery-request"
  hold_lock "${GVPN_RUN_DIR}/support-window.lock"
  "${CLI}" close > "${SANDBOX}/close.out" 2>&1 &
  closer=$!
  sleep 0.5
  waited=0
  [[ -e "${GVPN_STATE_DIR}/support-until" && -e "${GVPN_STATE_DIR}/recovery-request" ]] && waited=1
  release_lock
  wait "${closer}"
  [ "${waited}" -eq 1 ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
  [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
}
