#!/usr/bin/env bash
# gvpn-exit-update-apply.service: reboot into a staged deployment.
#
# Proceeds only if (a) bootc has a staged deployment, (b) local time is inside
# the maintenance window 03:00-05:59 (checked here, so a Persistent=true
# catch-up run at 14:00 after downtime never reboots), unless an operator
# explicitly passes --now, and (c) hoprd is not in the middle of a start/stop.
# Then stops hoprd cleanly, takes a reflink
# snapshot of its DB for the current deployment, releases the staged
# deployment (staged with --download-only, so no other reboot applies it),
# records data ownership for data-guard.sh and reboots. A failed snapshot or
# release never reboots; the next window retries.
#
# The unit runs this under /run/gvpn-exit/update.lock, which staging holds
# too, so the staged deployment cannot change between the read below and the
# reboot.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

GVPN_REFLINK="${GVPN_REFLINK:-always}"
WINDOW_START_HOUR=3
WINDOW_END_HOUR=6

in_maintenance_window() {
  local hour
  hour="$(date -d "@$(now_epoch)" +%-H)"
  (( hour >= WINDOW_START_HOUR && hour < WINDOW_END_HOUR ))
}

hoprd_is_transitioning() {
  local state
  state="$(systemctl show -p ActiveState --value hoprd.service)"
  [[ "${state}" == "activating" || "${state}" == "deactivating" || "${state}" == "reloading" ]]
}

# Copy the hoprd DB to the snapshot slot of deployment $1, replacing any
# previous snapshot of that deployment only once the new copy is complete.
snapshot_data() {
  local deployment="$1"
  local dest="${GVPN_HOPRD_SNAPSHOTS}/${deployment}"
  rm -rf "${dest}.tmp"
  if [[ -d "${GVPN_HOPRD_DATA}" ]]; then
    cp -a --reflink="${GVPN_REFLINK}" "${GVPN_HOPRD_DATA}" "${dest}.tmp" || return 1
  else
    log "no hoprd data at ${GVPN_HOPRD_DATA}; recording an empty snapshot"
    mkdir "${dest}.tmp" || return 1
  fi
  rm -rf "${dest}"
  mv "${dest}.tmp" "${dest}"
}

main() {
  local staged current apply_now="${1:-}"
  if (( $# > 1 )) || [[ -n "${apply_now}" && "${apply_now}" != --now ]]; then
    log "usage: ${0} [--now]"
    return 64
  fi
  staged="$(staged_image_digest)"
  if [[ -z "${staged}" ]]; then
    log "no staged deployment"
    return 0
  fi
  # update-allowed.sh checks the channel tag before staging, but the tag can
  # move before bootc pulls it: the staged digest itself is checked here.
  if digest_rejected "${staged}"; then
    log "staged update ${staged} was rejected by greenboot on this device before; not applying it"
    return 0
  fi
  if [[ "${apply_now}" != --now ]] && ! in_maintenance_window; then
    log "update ${staged} is staged; outside the maintenance window, waiting for the next one"
    return 0
  fi
  if hoprd_is_transitioning; then
    log "hoprd is starting or stopping; retry later"
    return 0
  fi
  current="$(booted_image_digest)"
  # An empty digest makes the snapshot destination the snapshots directory itself.
  if [[ -z "${current}" ]]; then
    log "ERROR booted image digest is empty; not applying staged update"
    return 1
  fi

  log "applying ${staged} (current ${current}): stopping hoprd for a consistent snapshot"
  systemctl stop hoprd.service
  if ! snapshot_data "${current}"; then
    log "ERROR snapshot of ${GVPN_HOPRD_DATA} failed; not rebooting"
    systemctl start hoprd.service
    return 1
  fi
  # Released before ownership is recorded, so a failed release leaves nothing
  # to undo.
  if ! bootc upgrade --from-downloaded --quiet; then
    log "ERROR cannot release the staged deployment ${staged}; not rebooting"
    systemctl start hoprd.service
    return 1
  fi

  # Previous first: until data-owner names the update, the current deployment
  # still owns the live data, so an interruption between the two writes
  # leaves a record under which the current deployment boots normally.
  echo "${current}" | write_atomic "${GVPN_STATE_DIR}/data-owner-previous"
  echo "${staged}" | write_atomic "${GVPN_STATE_DIR}/data-owner"
  sync
  log "snapshot taken; rebooting into ${staged}"
  systemctl reboot
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
