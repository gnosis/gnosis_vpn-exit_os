#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Wanted check: the configured Blokli indexer answers the query hoprd needs
# to start.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

blokli="$(provisioned_blokli_url)"
blokli_answers "${blokli}" || { echo "Blokli ${blokli} does not answer"; exit 1; }
echo "Blokli answers"
