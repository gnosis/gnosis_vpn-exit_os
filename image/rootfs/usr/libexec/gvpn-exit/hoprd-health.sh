#!/usr/bin/env bash
# hoprd-health.service (every minute via hoprd-health.timer). Watches hoprd's
# REST health endpoint.
#
# 1. Publish two textfile metrics for node_exporter: systemd's restart counter
#    (a gauge: it counts only Restart= restarts and every other start zeroes
#    it) and the watchdog's own restart counter, which never resets.
# 2. Restart hoprd once its health endpoint failed 3 consecutive probes. No
#    probing while systemd itself is (re)starting the unit, nor within 15 min
#    of a start, so a slow startup is never mistaken for a hang. The watchdog
#    only acts after a probe succeeded during the current start: an unfunded
#    node keeps its API closed by design and restarting it changes nothing.
#    try-restart leaves a stopped hoprd stopped: update-apply.sh may have
#    stopped it for its snapshot while the probe ran.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

GVPN_TEXTFILE_DIR="${GVPN_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
HEALTH_URL="${HOPRD_HEALTH_URL:-http://127.0.0.1:3001/healthyz}"
FAILURE_FILE="${GVPN_RUN_DIR}/hoprd-health.failures"
# ActiveEnterTimestamp of the last start during which a probe succeeded.
HEALTHY_MARK="${GVPN_RUN_DIR}/hoprd-health.healthy"
WATCHDOG_COUNTER="${GVPN_STATE_DIR}/hoprd-watchdog-restarts"
GRACE_S=900
MAX_FAILURES=3

write_metrics() {
  local nrestarts watchdog
  nrestarts="$(systemctl show -p NRestarts --value hoprd.service 2>/dev/null || true)"
  watchdog="$(watchdog_restarts)"
  mkdir -p "${GVPN_TEXTFILE_DIR}"
  write_atomic "${GVPN_TEXTFILE_DIR}/hoprd_restarts.prom" <<EOF
# HELP hoprd_service_restarts_systemd Restarts of hoprd.service systemd performed for Restart=; any other start zeroes the counter.
# TYPE hoprd_service_restarts_systemd gauge
hoprd_service_restarts_systemd ${nrestarts:-0}
# HELP hoprd_watchdog_restarts_total Restarts of hoprd.service the health watchdog performed since provisioning.
# TYPE hoprd_watchdog_restarts_total counter
hoprd_watchdog_restarts_total ${watchdog}
EOF
}

watchdog_restarts() {
  if [[ -s "${WATCHDOG_COUNTER}" ]]; then
    cat "${WATCHDOG_COUNTER}"
  else
    echo 0
  fi
}

failures() {
  if [[ -s "${FAILURE_FILE}" ]]; then
    cat "${FAILURE_FILE}"
  else
    echo 0
  fi
}

# Whether a probe succeeded since hoprd was last started ($1 is the start's
# ActiveEnterTimestamp): until then the watchdog stays disarmed.
healthy_since_start() {
  [[ -s "${HEALTHY_MARK}" && "$(< "${HEALTHY_MARK}")" == "$1" ]]
}

main() {
  local state since count
  write_metrics

  state="$(systemctl show -p ActiveState --value hoprd.service)"
  if [[ "${state}" != "active" ]]; then
    log "hoprd.service is ${state}; leaving restarts to systemd"
    return 0
  fi
  since="$(systemctl show --timestamp=unix -p ActiveEnterTimestamp --value hoprd.service)"
  since="${since#@}"
  if (( $(now_epoch) - ${since:-0} < GRACE_S )); then
    log "hoprd started less than $((GRACE_S / 60)) min ago; not probing yet"
    return 0
  fi

  mkdir -p "${GVPN_RUN_DIR}"
  if curl -fsS --max-time 5 -o /dev/null "${HEALTH_URL}"; then
    echo 0 > "${FAILURE_FILE}"
    printf '%s\n' "${since}" > "${HEALTHY_MARK}"
    return 0
  fi
  count=$(( $(failures) + 1 ))
  if (( count >= MAX_FAILURES )); then
    if ! healthy_since_start "${since}"; then
      if (( $(failures) < MAX_FAILURES )); then
        log "hoprd has not answered a health probe since it started; leaving restarts to systemd"
      fi
      echo "${MAX_FAILURES}" > "${FAILURE_FILE}"
      return 0
    fi
    log "hoprd health endpoint failed ${count} consecutive probes; restarting hoprd"
    echo 0 > "${FAILURE_FILE}"
    echo $(( $(watchdog_restarts) + 1 )) | write_atomic "${WATCHDOG_COUNTER}"
    systemctl try-restart hoprd.service
  else
    log "hoprd health endpoint failed (${count}/${MAX_FAILURES})"
    echo "${count}" > "${FAILURE_FILE}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
