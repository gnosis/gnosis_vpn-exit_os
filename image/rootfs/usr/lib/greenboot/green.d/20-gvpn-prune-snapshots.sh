#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"

# After a healthy boot, drop hoprd snapshots of deployments bootc no longer has.
snapshots="${GVPN_HOPRD_SNAPSHOTS:-/var/lib/hoprd-v5.snapshots}"
v4_snapshots="${GVPN_HOPRD_V4_SNAPSHOTS:-/var/lib/hoprd.snapshots}"
[[ -d "${snapshots}" || -d "${v4_snapshots}" ]] || exit 0
# update-apply.sh writes <digest>.tmp while it holds this lock, from reading the
# staged digest to the reboot.
update_lock="${GVPN_UPDATE_LOCK:-/run/gvpn-exit/update.lock}"

# Hold the update lock on fd 9 for the rest of the run, without waiting: a green
# boot never blocks on an update. A lock that cannot be taken is read as
# "running", so the .tmp entries are left alone: a snapshot is never removed
# from under a copy.
hold_update_lock() {
  local dir
  dir="$(dirname "${update_lock}")"
  [[ -d "${dir}" ]] || mkdir -p "${dir}" 2>/dev/null || return 1
  # The redirection silences only the open: as a bare exec it would silence
  # every later error as well.
  { exec 9>"${update_lock}"; } 2>/dev/null || return 1
  flock -n 9
}

# Taken once for the whole prune, and before the first removal, so an update
# that starts between two removals finds the lock taken.
if hold_update_lock; then
  prune_locked=1
else
  prune_locked=0
fi
# Every lookup must succeed first: a digest missing from the keep list would
# prune that deployment's snapshot. Read after the lock, so a staging that
# completes while the lock is being taken is in the keep list.
if ! booted="$(booted_image_digest)" || [[ -z "${booted}" ]] \
    || ! rollback="$(rollback_image_digest)" || ! staged="$(staged_image_digest)"; then
  echo "cannot read the deployments from bootc status; not pruning"
  exit 1
fi
for dir in "${snapshots}" "${v4_snapshots}"; do
  [[ -d "${dir}" ]] || continue
  while IFS= read -r stale; do
    [[ -n "${stale}" ]] || continue
    if [[ "${stale}" == *.tmp ]] && (( ! prune_locked )); then
      echo "keeping ${stale}: an update is applying"
      continue
    fi
    rm -rf "${stale}"
    echo "pruned ${stale}"
  done < <(snapshots_to_prune "${dir}" "${booted}" "${rollback}" "${staged}")
done
