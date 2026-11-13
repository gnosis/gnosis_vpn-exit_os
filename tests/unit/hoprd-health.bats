#!/usr/bin/env bats
# hoprd-health.sh (every minute): publishes the restart metrics for
# node_exporter and restarts hoprd after 3 consecutive failed health probes,
# but never during the 15 min grace period after a start and only once a probe
# succeeded since that start.

load helpers

NOW=1790220600

setup() {
  setup_sandbox
  export GVPN_NOW="${NOW}"
  export GVPN_TEXTFILE_DIR="${SANDBOX}/textfile"
  hoprd_unit active 4 $((NOW - 3600))
  mock_cmd curl 'exit 0'
}

teardown() {
  teardown_sandbox
}

# hoprd_unit ACTIVE_STATE NRESTARTS ACTIVE_SINCE_EPOCH
hoprd_unit() {
  mock_cmd systemctl "
case \"\$*\" in
  *'-p NRestarts'*) echo $2 ;;
  *'-p ActiveState'*) echo $1 ;;
  *'-p ActiveEnterTimestamp'*) echo @$3 ;;
esac"
}

# One successful probe arms the watchdog for the current start.
arm_watchdog() {
  run "${LIBEXEC}/hoprd-health.sh"
}

@test "publishes systemd's restarts as a gauge and the watchdog's as a counter" {
  printf '2\n' > "${GVPN_STATE_DIR}/hoprd-watchdog-restarts"
  run "${LIBEXEC}/hoprd-health.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'hoprd_service_restarts_systemd 4' "${GVPN_TEXTFILE_DIR}/hoprd_restarts.prom"
  grep -q '^# TYPE hoprd_service_restarts_systemd gauge' "${GVPN_TEXTFILE_DIR}/hoprd_restarts.prom"
  grep -qx 'hoprd_watchdog_restarts_total 2' "${GVPN_TEXTFILE_DIR}/hoprd_restarts.prom"
  grep -q '^# TYPE hoprd_watchdog_restarts_total counter' "${GVPN_TEXTFILE_DIR}/hoprd_restarts.prom"
}

@test "probes the unauthenticated health endpoint on loopback" {
  run "${LIBEXEC}/hoprd-health.sh"
  grep -q 'curl .*http://127.0.0.1:3001/healthyz' "${MOCK_LOG}"
}

@test "skips probing while hoprd is not active" {
  hoprd_unit activating 4 $((NOW - 3600))
  run "${LIBEXEC}/hoprd-health.sh"
  [ "${status}" -eq 0 ]
  ! grep -q '^curl' "${MOCK_LOG}"
}

@test "skips probing during the 15 minute grace period after a start" {
  hoprd_unit active 4 $((NOW - 600))
  run "${LIBEXEC}/hoprd-health.sh"
  [ "${status}" -eq 0 ]
  ! grep -q '^curl' "${MOCK_LOG}"
}

@test "does not restart hoprd that has not been healthy since it started" {
  # An unfunded node keeps its API closed by design: restarting it every 18
  # minutes changes nothing, so the watchdog stays disarmed until a probe
  # succeeded during this start.
  mock_cmd curl 'exit 22'
  for _ in 1 2 3 4; do run "${LIBEXEC}/hoprd-health.sh"; done
  ! grep -q 'systemctl try-restart hoprd.service' "${MOCK_LOG}"
}

@test "counts watchdog restarts in their own persistent counter" {
  arm_watchdog
  mock_cmd curl 'exit 22'
  for _ in 1 2 3; do run "${LIBEXEC}/hoprd-health.sh"; done
  [ "$(cat "${GVPN_STATE_DIR}/hoprd-watchdog-restarts")" -eq 1 ]
}

@test "restarts hoprd on the third consecutive failure only" {
  arm_watchdog
  mock_cmd curl 'exit 22'
  run "${LIBEXEC}/hoprd-health.sh"
  run "${LIBEXEC}/hoprd-health.sh"
  ! grep -q 'systemctl try-restart hoprd.service' "${MOCK_LOG}"
  run "${LIBEXEC}/hoprd-health.sh"
  [ "${status}" -eq 0 ]
  grep -q 'systemctl try-restart hoprd.service' "${MOCK_LOG}"
}

@test "a healthy probe resets the failure streak" {
  arm_watchdog
  mock_cmd curl 'exit 22'
  run "${LIBEXEC}/hoprd-health.sh"
  run "${LIBEXEC}/hoprd-health.sh"
  mock_cmd curl 'exit 0'
  run "${LIBEXEC}/hoprd-health.sh"
  mock_cmd curl 'exit 22'
  run "${LIBEXEC}/hoprd-health.sh"
  run "${LIBEXEC}/hoprd-health.sh"
  ! grep -q 'systemctl try-restart hoprd.service' "${MOCK_LOG}"
}

@test "the failure streak starts over after a restart" {
  arm_watchdog
  mock_cmd curl 'exit 22'
  for _ in 1 2 3; do run "${LIBEXEC}/hoprd-health.sh"; done
  [ "$(grep -c 'systemctl try-restart hoprd.service' "${MOCK_LOG}")" -eq 1 ]
  run "${LIBEXEC}/hoprd-health.sh"
  [ "$(grep -c 'systemctl try-restart hoprd.service' "${MOCK_LOG}")" -eq 1 ]
}

@test "restarts only a running hoprd, never one update-apply stopped for its snapshot" {
  # try-restart is a no-op on a stopped unit, so a probe that started before
  # update-apply.sh stopped hoprd cannot bring it back during the snapshot.
  arm_watchdog
  mock_cmd curl 'exit 22'
  for _ in 1 2 3; do run "${LIBEXEC}/hoprd-health.sh"; done
  grep -qx 'systemctl try-restart hoprd.service' "${MOCK_LOG}"
  ! grep -q 'systemctl restart' "${MOCK_LOG}"
}
