#!/usr/bin/env bats
# data-guard.sh runs before hoprd on every boot and makes sure the hoprd DB
# belongs to the booted deployment, restoring the pre-update snapshot after a
# rollback.

load helpers

setup() {
  setup_sandbox
  export GVPN_HOPRD_DATA="${SANDBOX}/lib/hoprd"
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/lib/hoprd.snapshots"
  export GVPN_REFLINK=auto
  export GVPN_NOW=1790000000
  mkdir -p "${GVPN_HOPRD_DATA}" "${GVPN_HOPRD_SNAPSHOTS}"
  echo "live" > "${GVPN_HOPRD_DATA}/db"
}

teardown() {
  teardown_sandbox
}

booted() {
  mock_cmd bootc "echo '{\"status\":{\"booted\":{\"image\":{\"imageDigest\":\"$1\"}}}}'"
}

@test "does nothing when the booted deployment owns the data" {
  booted sha256:new
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_HOPRD_DATA}/db")" = "live" ]
}

@test "restores the snapshot after a rollback to the previous deployment" {
  booted sha256:old
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  echo sha256:old > "${GVPN_STATE_DIR}/data-owner-previous"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:old"
  echo "snapshot" > "${GVPN_HOPRD_SNAPSHOTS}/sha256:old/db"
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_HOPRD_DATA}/db")" = "snapshot" ]
  [ "$(cat "${GVPN_STATE_DIR}/data-owner")" = "sha256:old" ]
  [ "$(cat "${SANDBOX}/lib/hoprd.rejected-1790000000/db")" = "live" ]
  [[ "${output}" == *"restored"* ]]
}

@test "keeps the snapshot after restoring it" {
  booted sha256:old
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  echo sha256:old > "${GVPN_STATE_DIR}/data-owner-previous"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:old"
  echo "snapshot" > "${GVPN_HOPRD_SNAPSHOTS}/sha256:old/db"
  run "${LIBEXEC}/data-guard.sh"
  [ "$(cat "${GVPN_HOPRD_SNAPSHOTS}/sha256:old/db")" = "snapshot" ]
}

@test "fails and leaves the data alone when the rollback snapshot is missing" {
  booted sha256:old
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  echo sha256:old > "${GVPN_STATE_DIR}/data-owner-previous"
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -ne 0 ]
  [ "$(cat "${GVPN_HOPRD_DATA}/db")" = "live" ]
  [ "$(cat "${GVPN_STATE_DIR}/data-owner")" = "sha256:new" ]
}

@test "fails on a deployment that is neither owner nor previous owner" {
  booted sha256:other
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  echo sha256:old > "${GVPN_STATE_DIR}/data-owner-previous"
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -ne 0 ]
  [ "$(cat "${GVPN_HOPRD_DATA}/db")" = "live" ]
}

@test "fails when no data owner was ever recorded" {
  booted sha256:new
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"data-owner"* ]]
}

@test "fails when bootc reports no booted image digest" {
  mock_cmd bootc 'echo "{\"status\":{\"booted\":null}}"'
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -ne 0 ]
}

@test "prunes rejected data older than seven days and keeps recent ones" {
  booted sha256:new
  echo sha256:new > "${GVPN_STATE_DIR}/data-owner"
  old=$((GVPN_NOW - 8 * 86400))
  recent=$((GVPN_NOW - 6 * 86400))
  mkdir -p "${SANDBOX}/lib/hoprd.rejected-${old}" "${SANDBOX}/lib/hoprd.rejected-${recent}"
  run "${LIBEXEC}/data-guard.sh"
  [ "${status}" -eq 0 ]
  [ ! -e "${SANDBOX}/lib/hoprd.rejected-${old}" ]
  [ -d "${SANDBOX}/lib/hoprd.rejected-${recent}" ]
}
