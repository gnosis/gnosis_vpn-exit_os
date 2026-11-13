#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Wanted check: hoprd reports itself healthy.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3001/healthyz || { echo "hoprd /healthyz not OK"; exit 1; }
echo "hoprd healthy"
