#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Boot declared healthy: log the running image and report green.
bootc status --format=humanreadable || true
if is_provisioned && [[ -f /etc/gvpn-exit/fleet.env ]]; then
  /usr/libexec/gvpn-exit/heartbeat.sh --status green || echo "green heartbeat failed"
fi
