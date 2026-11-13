#!/usr/bin/env bash
# gvpn-exit-data-guard.service: runs on every boot before hoprd.
#
# bootc/greenboot rollback only changes which deployment boots; /var/lib/hoprd-v5
# is shared by all v5 deployments. update-apply.sh snapshots the DB and records
# ownership before rebooting into a staged deployment:
#   data-owner          = deployment (image digest) the live DB belongs to
#   data-owner-previous = deployment the snapshot was taken on
#
# Decision on boot, by booted image digest:
#   == data-owner           -> nothing to do
#   == data-owner-previous  -> we rolled back: set the live DB aside as
#                              hoprd.rejected-<epoch>, restore the snapshot of
#                              this deployment, make it the owner
#   anything else           -> fail; hoprd (Requires=) does not start and the
#                              greenboot required check 50-data-guard goes red
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

GVPN_REFLINK="${GVPN_REFLINK:-always}"
REJECTED_RETENTION_S=$((7 * 86400))

# Remove rejected DB copies whose embedded timestamp is older than the retention.
prune_rejected() {
  local dir stamp cutoff
  cutoff=$(( $(now_epoch) - REJECTED_RETENTION_S ))
  for dir in "${GVPN_HOPRD_DATA}".rejected-*; do
    [[ -d "${dir}" ]] || continue
    stamp="${dir##*.rejected-}"
    [[ "${stamp}" =~ ^[0-9]+$ ]] || continue
    if (( stamp < cutoff )); then
      rm -rf "${dir}"
      log "pruned ${dir}"
    fi
  done
}

restore_snapshot() {
  local deployment="$1"
  local snapshot="${GVPN_HOPRD_SNAPSHOTS}/${deployment}"
  local rejected
  rejected="${GVPN_HOPRD_DATA}.rejected-$(now_epoch)"

  if [[ ! -d "${snapshot}" ]]; then
    log "ERROR rolled back to ${deployment} but no snapshot exists at ${snapshot}; not touching ${GVPN_HOPRD_DATA}"
    return 1
  fi
  if [[ -e "${GVPN_HOPRD_DATA}" ]]; then
    mv "${GVPN_HOPRD_DATA}" "${rejected}"
  fi
  cp -a --reflink="${GVPN_REFLINK}" "${snapshot}" "${GVPN_HOPRD_DATA}"
  echo "${deployment}" | write_atomic "${GVPN_STATE_DIR}/data-owner"
  sync
  log "ROLLBACK DETECTED: restored hoprd data snapshot of ${deployment}; data of the rejected deployment kept at ${rejected}"
}

main() {
  local booted owner previous=""
  booted="$(booted_image_digest)"
  if [[ -z "${booted}" ]]; then
    log "ERROR bootc reports no booted image digest"
    return 1
  fi
  if [[ ! -s "${GVPN_STATE_DIR}/data-owner" ]]; then
    log "ERROR ${GVPN_STATE_DIR}/data-owner is missing; provisioning did not record the data owner"
    return 1
  fi
  owner="$(< "${GVPN_STATE_DIR}/data-owner")"
  if [[ -s "${GVPN_STATE_DIR}/data-owner-previous" ]]; then
    previous="$(< "${GVPN_STATE_DIR}/data-owner-previous")"
  fi

  prune_rejected

  if [[ "${booted}" == "${owner}" ]]; then
    log "hoprd data belongs to the booted deployment ${booted}"
    return 0
  fi
  if [[ -n "${previous}" && "${booted}" == "${previous}" ]]; then
    restore_snapshot "${booted}"
    return
  fi
  log "ERROR booted deployment ${booted} owns neither the live hoprd data (${owner}) nor the snapshot (${previous:-none})"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
