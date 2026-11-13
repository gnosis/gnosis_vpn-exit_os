#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Wanted check: local observability answers.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:19999/api/v1/info || { echo "netdata not answering"; exit 1; }
curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:9100/metrics || { echo "node_exporter not answering"; exit 1; }
echo "netdata and node_exporter answering"
