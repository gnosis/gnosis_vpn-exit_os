#!/usr/bin/env bash
# ExecCondition of gvpn-exit-update-stage.service.
#
# Resolves the digest the tracked channel tag points at and refuses to stage
# it again if greenboot already rejected it (red.d records rejected digests).
# ExecCondition semantics: exit 0 runs the upgrade, exit 1 skips it without
# failing the unit. A later, different digest on the channel is staged
# normally.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

main() {
  local ref digest
  ref="$(bootc_status_json | jq -r '.spec.image.image // empty')"
  if [[ -z "${ref}" ]]; then
    log "system does not track an image; nothing to stage"
    return 1
  fi
  if ! digest="$(skopeo inspect --no-tags --format '{{.Digest}}' "docker://${ref}")"; then
    log "cannot resolve ${ref}; skipping this staging run"
    return 1
  fi
  if digest_rejected "${digest}"; then
    log "${ref} points at ${digest}, which greenboot rejected on this device; not staging it again"
    return 1
  fi
  log "${ref} points at ${digest}; staging allowed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
