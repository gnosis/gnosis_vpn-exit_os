#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Required check: gnosis_vpn-server answers and owns a correctly configured
# wggvpn interface rendered from the sealed key.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

load_exit_env
conf="${GVPN_SERVER_RUN_DIR:-/run/gnosisvpn-server}/wggvpn.conf"
# The server is Type=simple and brings wggvpn up after it starts, so the check
# waits for readiness instead of racing the first second of startup.
READY_TIMEOUT_S="${GVPN_READY_TIMEOUT_S:-60}"
REASON=""

server_ready() {
  if ! curl -fsS --max-time 5 -o /dev/null "http://${GVPN_SERVER_ENDPOINT}/api/v1/ping"; then
    REASON="gnosis_vpn-server does not answer on ${GVPN_SERVER_ENDPOINT}"
    return 1
  fi
  local port
  port="$(wg show wggvpn listen-port 2>/dev/null)" || port=""
  if [[ "${port}" != "${WIREGUARD_PORT}" ]]; then
    REASON="wggvpn listens on ${port:-nothing}, expected ${WIREGUARD_PORT}"
    return 1
  fi
  if [[ "$(stat -c %a "${conf}" 2>/dev/null)" != "600" ]]; then
    REASON="${conf} is not mode 0600"
    return 1
  fi
}

if ! wait_for "${READY_TIMEOUT_S}" server_ready; then
  echo "${REASON:-gnosis_vpn-server did not become ready within ${READY_TIMEOUT_S}s}"
  exit 1
fi
echo "gnosis_vpn-server up, wggvpn on ${WIREGUARD_PORT}"
