#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Required check: the hoprd DB belongs to the booted deployment (or the
# pre-update snapshot was restored after a rollback).
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

result="$(systemctl show -p Result --value gvpn-exit-data-guard.service)"
state="$(systemctl show -p ActiveState --value gvpn-exit-data-guard.service)"
if [[ "${result}" != "success" || "${state}" != "active" ]]; then
  echo "gvpn-exit-data-guard.service is ${state}/${result}"
  exit 1
fi
echo "hoprd data owned by the booted deployment"
