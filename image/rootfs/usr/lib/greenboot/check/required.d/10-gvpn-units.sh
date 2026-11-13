#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Required check: the software stack is up and did not crash-loop. Offline
# health only; hoprd chain sync is deliberately not required.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

UNITS_TIMEOUT_S="${GVPN_UNITS_TIMEOUT_S:-180}"
HOPRD_STABLE_S="${GVPN_HOPRD_STABLE_S:-60}"

wait_units_active "${UNITS_TIMEOUT_S}" gvpn-exit-firewall.service gvpn-exit-data-guard.service \
  gvpn-blocklist-boot.service gnosisvpn-server.service \
  node_exporter.service netdata.service sshd.service

restarts="$(systemctl show -p NRestarts --value gnosisvpn-server.service)"
if [[ "${restarts}" != "0" ]]; then
  echo "gnosisvpn-server.service restarted ${restarts} times since boot"
  exit 1
fi

# An updated v4 device has no v5 provisioning file until the operator runs
# gvpn-exit-hoprd-migrate; hoprd.service is held stopped by its own condition.
# That is a migration step, not a red boot.
if ! hoprd_v5_configured; then
  echo "hoprd v5 is not configured yet; run sudo gvpn-exit-hoprd-migrate migrate"
  exit 0
fi

# hoprd exits when Blokli does not answer its startup query, and systemd
# retries it every 30 s: a connectivity problem, which wanted.d reports. So
# hoprd is judged only while Blokli answers, and by staying up rather than by
# its restarts since boot, which may be retries from before Blokli answered.
blokli="$(provisioned_blokli_url)"
if ! blokli_answers "${blokli}"; then
  echo "Blokli ${blokli} does not answer; hoprd not judged, all other units active"
  exit 0
fi
wait_units_active "${UNITS_TIMEOUT_S}" hoprd.service
if ! unit_stays_up hoprd.service "${HOPRD_STABLE_S}"; then
  echo "hoprd.service did not stay up for ${HOPRD_STABLE_S}s while Blokli answers"
  exit 1
fi
echo "all units active, no restarts"
