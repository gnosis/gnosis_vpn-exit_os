#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Required check: per-peer shaping trees are installed on both directions.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

# wg-quick runs wg-hooks.sh, which builds the trees, after the interface comes
# up; wait for both instead of racing gnosisvpn-server's startup.
READY_TIMEOUT_S="${GVPN_READY_TIMEOUT_S:-60}"
REASON=""

shaping_ready() {
  if ! tc qdisc show dev wggvpn root 2>/dev/null | grep -q '^qdisc htb 1: root'; then
    REASON="no htb root on wggvpn"
    return 1
  fi
  if ! ip link show ifb-gvpn up 2>/dev/null | grep -q ifb-gvpn; then
    REASON="ifb-gvpn missing or down"
    return 1
  fi
  if ! tc qdisc show dev ifb-gvpn root 2>/dev/null | grep -q '^qdisc htb 1: root'; then
    REASON="no htb root on ifb-gvpn"
    return 1
  fi
}

if ! wait_for "${READY_TIMEOUT_S}" shaping_ready; then
  echo "${REASON:-shaping did not appear within ${READY_TIMEOUT_S}s}"
  exit 1
fi
echo "shaping in place"
