#!/usr/bin/env bats
# support-window.sh decides whether the support tunnel may run. The file's
# existence alone never suffices: it must parse, the clock must be NTP-synced
# and now must be before the deadline.

load helpers

NOW=1790220600 # 2026-09-24T03:30:00Z

setup() {
  setup_sandbox
  export GVPN_NOW="${NOW}"
  ntp yes
  mock_cmd systemctl
}

teardown() {
  teardown_sandbox
}

ntp() {
  mock_cmd timedatectl "echo $1"
}

until_file() {
  echo "$1" > "${GVPN_STATE_DIR}/support-until"
}

@test "check passes for a future deadline with a synced clock" {
  until_file "2026-10-24T00:00:00Z"
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 0 ]
}

@test "check fails when the file is missing" {
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 1 ]
}

@test "check fails on an unparsable deadline" {
  until_file "next tuesday-ish"
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 1 ]
}

@test "check fails once the deadline has passed" {
  until_file "2026-09-24T03:29:59Z"
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 1 ]
}

@test "check fails at exactly the deadline" {
  until_file "2026-09-24T03:30:00Z"
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 1 ]
}

@test "check fails while the clock is not NTP-synchronized" {
  until_file "2026-10-24T00:00:00Z"
  ntp no
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"NTP"* ]]
}

@test "enforce stops the tunnel and removes an expired window" {
  until_file "2026-09-01T00:00:00Z"
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  grep -q 'systemctl stop support-tunnel.service' "${MOCK_LOG}"
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "enforce keeps an open window and never stops its tunnel" {
  until_file "2026-10-24T00:00:00Z"
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  run grep 'systemctl stop' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [ -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "enforce starts the tunnel inside an open window (boot before NTP sync)" {
  until_file "2026-10-24T00:00:00Z"
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  grep -qx 'systemctl start support-tunnel.service' "${MOCK_LOG}"
}

@test "enforce never starts the tunnel outside a trusted open window" {
  until_file "2026-10-24T00:00:00Z"
  ntp no
  run "${LIBEXEC}/support-window.sh" enforce
  until_file "2026-09-01T00:00:00Z"
  ntp yes
  run "${LIBEXEC}/support-window.sh" enforce
  run grep 'systemctl start' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "enforce keeps the window while the clock is unsynced but stops the tunnel" {
  until_file "2026-10-24T00:00:00Z"
  ntp no
  run "${LIBEXEC}/support-window.sh" enforce
  grep -q 'systemctl stop support-tunnel.service' "${MOCK_LOG}"
  [ -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "usage error on an unknown action" {
  run "${LIBEXEC}/support-window.sh" maybe
  [ "${status}" -eq 64 ]
}

@test "enforce keeps a valid window while an unsynced clock runs past its deadline" {
  until_file "2026-10-24T00:00:00Z"
  ntp no
  export GVPN_NOW="$(date -u -d 2027-01-01 +%s)"
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  grep -q 'systemctl stop support-tunnel.service' "${MOCK_LOG}"
  [ -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "enforce removes an unparsable window whatever the clock" {
  until_file "next tuesday-ish"
  ntp no
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

# A recovery stick leaves a day count instead of a deadline, because its clock
# is the appliance's own RTC. Only this timer may turn it into a deadline.
request_file() {
  echo "$1" >"${GVPN_STATE_DIR}/recovery-request"
}

@test "a recovery request waits while the clock is not NTP-synchronized" {
  request_file 7
  ntp no
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ -e "${GVPN_STATE_DIR}/recovery-request" ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "a recovery request opens the window from the trusted clock" {
  request_file 7
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_STATE_DIR}/support-until")" = "2026-10-01T03:30:00Z" ]
  [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
  grep -qx 'systemctl start support-tunnel.service' "${MOCK_LOG}"
}

@test "a recovery request cannot open a window past the shared bound" {
  request_file 91
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "an unparsable recovery request is dropped and opens nothing" {
  request_file seven
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

# A leading zero is not a day count: `010` would be read as octal and `08`
# aborts the arithmetic with a bash error instead of dropping the request.
@test "a recovery request with a leading zero is dropped without an arithmetic error" {
  local days
  for days in 08 010; do
    request_file "${days}"
    run "${LIBEXEC}/support-window.sh" enforce
    [ "${status}" -eq 0 ]
    [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
    [ ! -e "${GVPN_STATE_DIR}/support-until" ]
    [[ "${output}" != *"value too great for base"* ]]
    [[ "${output}" == *"invalid day count"* ]]
  done
}

# The stick also dates its keys from the RTC. The timer moves the expiry of
# the lines carrying the stick's marker to the window's deadline, and nothing
# else in the file.
keys_file() {
  printf '%s\n' "${GVPN_DEVOPS_AUTHORIZED_KEYS}"
}

stick_keys() {
  export GVPN_DEVOPS_AUTHORIZED_KEYS="${SANDBOX}/authorized_keys"
  cat >"$(keys_file)" <<'KEYS'
ssh-ed25519 AAAApresent installer@laptop
expiry-time="20270101Z" ssh-ed25519 AAAAoperator9 ops@laptop
expiry-time="20000108Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20000101
KEYS
}

@test "a recovery request re-times the stick's keys from the trusted clock" {
  stick_keys
  request_file 7
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  grep -qx 'expiry-time="202610010330Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20000101' "$(keys_file)"
  grep -qx 'ssh-ed25519 AAAApresent installer@laptop' "$(keys_file)"
  grep -qx 'expiry-time="20270101Z" ssh-ed25519 AAAAoperator9 ops@laptop' "$(keys_file)"
}

@test "re-timing the keys keeps the key file's inode" {
  local inode
  stick_keys
  inode="$(stat -c %i "$(keys_file)")"
  request_file 7
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ "$(stat -c %i "$(keys_file)")" = "${inode}" ]
}

@test "the stick's keys keep their expiry while the clock is not NTP-synchronized" {
  stick_keys
  request_file 7
  ntp no
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  grep -qx 'expiry-time="20000108Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20000101' "$(keys_file)"
}

@test "a recovery request opens the window when devops has no key file" {
  export GVPN_DEVOPS_AUTHORIZED_KEYS="${SANDBOX}/missing/authorized_keys"
  request_file 7
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_STATE_DIR}/support-until")" = "2026-10-01T03:30:00Z" ]
  [ ! -e "${GVPN_DEVOPS_AUTHORIZED_KEYS}" ]
}

# The timer and `gvpn-exit-support` both mutate the window, so they serialize
# on one lock: a request the timer has already read must not reopen a window
# that `close` removed in the meantime.
@test "enforce holds the support lock while it starts the tunnel" {
  request_file 7
  mock_cmd systemctl "if flock -n '${GVPN_RUN_DIR}/support-window.lock' -c true; then echo 'support lock not held' >&2; exit 1; fi"
  run "${LIBEXEC}/support-window.sh" enforce
  [ "${status}" -eq 0 ]
  grep -qx 'systemctl start support-tunnel.service' "${MOCK_LOG}"
}

@test "enforce waits for a close that holds the lock instead of reopening the window" {
  request_file 7
  # The lock is held the way `gvpn-exit-support close` holds it while it
  # removes the window and the request, so the timer must not read the request
  # until the close is done.
  hold_lock "${GVPN_RUN_DIR}/support-window.lock"
  "${LIBEXEC}/support-window.sh" enforce > "${SANDBOX}/enforce.out" 2>&1 &
  timer=$!
  sleep 0.5
  waited=0
  [[ -e "${GVPN_STATE_DIR}/recovery-request" && ! -e "${GVPN_STATE_DIR}/support-until" ]] && waited=1
  release_lock
  wait "${timer}"
  [ "${waited}" -eq 1 ]
  [ ! -e "${GVPN_STATE_DIR}/recovery-request" ]
  [ -e "${GVPN_STATE_DIR}/support-until" ]
}
