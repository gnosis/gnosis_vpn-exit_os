#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Required check. The gvpn checks below only apply to a provisioned device;
# each of them skips on its own because greenboot runs every script.
if is_provisioned; then
  echo "provisioned at $(< "${GVPN_IDENTITY_DIR}/provisioned")"
else
  echo "unprovisioned, gvpn checks skip"
fi
