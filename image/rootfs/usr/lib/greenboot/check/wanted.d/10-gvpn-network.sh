#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"
load_exit_env

# Wanted check (never triggers rollback): uplink and DNS.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

ip -4 route show default | grep -q . || { echo "no IPv4 default route"; exit 1; }
getent hosts "${GVPN_DNS_PROBE_HOST}" >/dev/null \
  || { echo "DNS does not resolve ${GVPN_DNS_PROBE_HOST}"; exit 1; }
echo "default route and DNS ok"
