#!/usr/bin/env bash
# ExecStop of greenboot-set-rollback-trigger.service (see the drop-in in
# /usr/lib/systemd/system/greenboot-set-rollback-trigger.service.d).
#
# greenboot-rs stores the staged deployment's digest as its rollback trigger on
# every orderly shutdown and runs `bootc rollback` when the next boot's digest
# differs. Only finalization obeys `bootc upgrade --download-only`; the trigger
# does not. A download-only update waits for the maintenance window and can be
# staged for hours, so an ordinary reboot in between would arm a rollback to
# the previous deployment, and data-guard would restore that deployment's DB
# snapshot. So: arm the trigger for everything except a download-only staged
# deployment, and keep arming it when the status cannot be read, so a real
# rollback trigger is never lost to a failed read.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# The unit's own command; /usr/libexec is not on PATH.
GREENBOOT_BIN="${GVPN_GREENBOOT_BIN:-/usr/libexec/greenboot/greenboot}"

main() {
  local download_only=false
  if download_only="$(bootc_status_json 2>/dev/null | jq -r '.status.staged.downloadOnly // false' 2>/dev/null)" \
      && [[ "${download_only}" == true ]]; then
    log "staged deployment is download-only; not arming the rollback trigger"
    return 0
  fi
  exec "${GREENBOOT_BIN}" set-rollback-trigger
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
