#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Wanted check: the blocklist ipset is populated.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

load_exit_env
entries="$(ipset list "${GVPN_BLOCKLIST_IPSET_NAME}" | awk '/Number of entries/ {print $4}')"
(( ${entries:-0} >= GVPN_BLOCKLIST_MIN_ENTRIES )) || { echo "blocklist has ${entries:-0} entries"; exit 1; }
echo "blocklist has ${entries} entries"
