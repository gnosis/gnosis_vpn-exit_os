#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# Boot failed its required checks: remember the image so update-allowed.sh
# does not stage it again (the last 10 rejections are kept), and report red
# (best effort).
digest="$(booted_image_digest || true)"
if [[ -n "${digest}" ]]; then
  record_rejected_digest "${digest}"
  echo "recorded ${digest} as rejected"
fi
if is_provisioned && [[ -f /etc/gvpn-exit/fleet.env ]]; then
  /usr/libexec/gvpn-exit/heartbeat.sh --status red || echo "red heartbeat failed"
fi
