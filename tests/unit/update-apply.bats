#!/usr/bin/env bats
# update-apply.sh reboots into a staged deployment only inside the
# maintenance window, after an application-consistent snapshot of the hoprd DB.

load helpers

# 2026-09-24 03:30:00 UTC and 14:00:00 UTC
IN_WINDOW=1790220600
OUT_OF_WINDOW=1790258400

setup() {
  setup_sandbox
  export TZ=UTC
  export GVPN_HOPRD_DATA="${SANDBOX}/lib/hoprd"
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/lib/hoprd.snapshots"
  export GVPN_REFLINK=auto
  export GVPN_NOW="${IN_WINDOW}"
  mkdir -p "${GVPN_HOPRD_DATA}" "${GVPN_HOPRD_SNAPSHOTS}"
  echo "db-v1" > "${GVPN_HOPRD_DATA}/db"
  staged sha256:new
  hoprd_state active
  mock_cmd sync
}

teardown() {
  teardown_sandbox
}

# `bootc upgrade` exits with ${BOOTC_UPGRADE_STATUS:-0}; anything else prints
# the status JSON.
staged() {
  local staged_json="null"
  [[ -n "$1" ]] && staged_json="{\"image\":{\"imageDigest\":\"$1\"},\"downloadOnly\":true}"
  mock_cmd bootc "[[ \"\$1\" == upgrade ]] && exit \${BOOTC_UPGRADE_STATUS:-0}
echo '{\"status\":{\"staged\":${staged_json},\"booted\":{\"image\":{\"imageDigest\":\"sha256:cur\"}}}}'"
}

staged_without_booted_digest() {
  mock_cmd bootc "[[ \"\$1\" == upgrade ]] && exit \${BOOTC_UPGRADE_STATUS:-0}
echo '{\"status\":{\"staged\":{\"image\":{\"imageDigest\":\"sha256:new\"},\"downloadOnly\":true},\"booted\":null}}'"
}

# Line number of the first recorded call matching $1, empty if none.
call_line() {
  grep -n -e "$1" "${MOCK_LOG}" | head -1 | cut -d: -f1
}

hoprd_state() {
  mock_cmd systemctl "[[ \"\$*\" == *'-p ActiveState'* ]] && echo $1; exit 0"
}

@test "does nothing without a staged deployment" {
  staged ""
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -eq 0 ]
  ! grep -q 'systemctl reboot' "${MOCK_LOG}"
  ! grep -q 'systemctl stop' "${MOCK_LOG}"
}

@test "waits for the window when an update is staged outside of it" {
  export GVPN_NOW="${OUT_OF_WINDOW}"
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"outside the maintenance window"* ]]
  ! grep -q 'systemctl reboot' "${MOCK_LOG}"
}

@test "--now applies outside the window with a snapshot and ownership records" {
  export GVPN_NOW="${OUT_OF_WINDOW}"
  run "${LIBEXEC}/update-apply.sh" --now
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_HOPRD_SNAPSHOTS}/sha256:cur/db")" = "db-v1" ]
  [ "$(cat "${GVPN_STATE_DIR}/data-owner")" = "sha256:new" ]
  [ "$(cat "${GVPN_STATE_DIR}/data-owner-previous")" = "sha256:cur" ]
  grep -q 'bootc upgrade --from-downloaded' "${MOCK_LOG}"
  grep -q 'systemctl reboot' "${MOCK_LOG}"
}

@test "invalid apply arguments fail without releasing or rebooting" {
  for args in '--force' '--now unexpected'; do
    # shellcheck disable=SC2086 # exercise both one and two arguments
    run "${LIBEXEC}/update-apply.sh" ${args}
    [ "${status}" -eq 64 ]
    [[ "${output}" == *"usage:"* ]]
    ! grep -q 'bootc upgrade' "${MOCK_LOG}"
    ! grep -q 'systemctl stop' "${MOCK_LOG}"
    ! grep -q 'systemctl reboot' "${MOCK_LOG}"
  done
}

@test "--now still refuses missing or rejected updates and transitioning hoprd" {
  export GVPN_NOW="${OUT_OF_WINDOW}"
  for reason in missing rejected transitioning; do
    staged sha256:new
    case "${reason}" in
      missing) staged "" ;;
      rejected) echo sha256:new > "${GVPN_STATE_DIR}/rejected-digests" ;;
      transitioning)
        rm "${GVPN_STATE_DIR}/rejected-digests"
        hoprd_state activating ;;
    esac
    run "${LIBEXEC}/update-apply.sh" --now
    [ "${status}" -eq 0 ]
    ! grep -q 'bootc upgrade' "${MOCK_LOG}"
    ! grep -q 'systemctl stop' "${MOCK_LOG}"
    ! grep -q 'systemctl reboot' "${MOCK_LOG}"
  done
}

@test "--now does not reboot or change ownership when snapshot or release fails" {
  export GVPN_NOW="${OUT_OF_WINDOW}"
  for reason in snapshot release; do
    : > "${MOCK_LOG}"
    case "${reason}" in
      snapshot) chmod 000 "${GVPN_HOPRD_SNAPSHOTS}" ;;
      release) export BOOTC_UPGRADE_STATUS=1 ;;
    esac
    run "${LIBEXEC}/update-apply.sh" --now
    chmod 755 "${GVPN_HOPRD_SNAPSHOTS}"
    [ "${status}" -ne 0 ]
    ! grep -q 'systemctl reboot' "${MOCK_LOG}"
    grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
    [ ! -e "${GVPN_STATE_DIR}/data-owner" ]
    [ ! -e "${GVPN_STATE_DIR}/data-owner-previous" ]
  done
}

@test "the window covers 03:00 up to 05:59" {
  for t in "03:00:00" "05:59:59"; do
    export GVPN_NOW="$(date -u -d "2026-09-24 ${t}" +%s)"
    run bash -c 'source "$1"; in_maintenance_window' _ "${LIBEXEC}/update-apply.sh"
    [ "${status}" -eq 0 ]
  done
  for t in "02:59:59" "06:00:00" "14:00:00"; do
    export GVPN_NOW="$(date -u -d "2026-09-24 ${t}" +%s)"
    run bash -c 'source "$1"; in_maintenance_window' _ "${LIBEXEC}/update-apply.sh"
    [ "${status}" -ne 0 ]
  done
}

@test "does not interrupt hoprd while it is restarting" {
  hoprd_state activating
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -eq 0 ]
  ! grep -q 'systemctl reboot' "${MOCK_LOG}"
  ! grep -q 'systemctl stop' "${MOCK_LOG}"
}

@test "refuses a staged update without a booted digest without touching snapshots" {
  staged_without_booted_digest
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback"
  echo "preserve" > "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback/db"

  run "${LIBEXEC}/update-apply.sh"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ERROR"*"booted image digest"* ]]
  [ "$(cat "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback/db")" = "preserve" ]
  ! grep -q 'systemctl stop hoprd.service' "${MOCK_LOG}"
  ! grep -q 'systemctl reboot' "${MOCK_LOG}"
}

@test "stops hoprd, snapshots, records ownership and reboots in the window" {
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_HOPRD_SNAPSHOTS}/sha256:cur/db")" = "db-v1" ]
  [ "$(cat "${GVPN_STATE_DIR}/data-owner")" = "sha256:new" ]
  [ "$(cat "${GVPN_STATE_DIR}/data-owner-previous")" = "sha256:cur" ]
  stop_line="$(grep -n 'systemctl stop hoprd.service' "${MOCK_LOG}" | cut -d: -f1)"
  reboot_line="$(grep -n 'systemctl reboot' "${MOCK_LOG}" | cut -d: -f1)"
  [ -n "${stop_line}" ] && [ -n "${reboot_line}" ]
  [ "${stop_line}" -lt "${reboot_line}" ]
}

@test "releases the downloaded update only after the snapshot, then reboots" {
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -eq 0 ]
  stop_line="$(call_line 'systemctl stop hoprd.service')"
  release_line="$(call_line 'bootc upgrade --from-downloaded')"
  reboot_line="$(call_line 'systemctl reboot')"
  [ -n "${stop_line}" ]
  [ -n "${release_line}" ]
  [ -n "${reboot_line}" ]
  [ "${stop_line}" -lt "${release_line}" ]
  [ "${release_line}" -lt "${reboot_line}" ]
  ! grep -q 'bootc upgrade --from-downloaded.*--apply' "${MOCK_LOG}"
}

@test "does not reboot, keeps ownership and restarts hoprd when the update cannot be released" {
  export BOOTC_UPGRADE_STATUS=1
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -ne 0 ]
  ! grep -q 'systemctl reboot' "${MOCK_LOG}"
  grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
  [ ! -e "${GVPN_STATE_DIR}/data-owner" ]
  [ ! -e "${GVPN_STATE_DIR}/data-owner-previous" ]
}

@test "replaces an older snapshot of the same deployment" {
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:cur"
  echo "stale" > "${GVPN_HOPRD_SNAPSHOTS}/sha256:cur/db"
  run "${LIBEXEC}/update-apply.sh"
  [ "$(cat "${GVPN_HOPRD_SNAPSHOTS}/sha256:cur/db")" = "db-v1" ]
  [ ! -e "${GVPN_HOPRD_SNAPSHOTS}/sha256:cur/hoprd" ]
}

@test "does not reboot and restarts hoprd when the snapshot fails" {
  chmod 000 "${GVPN_HOPRD_SNAPSHOTS}"
  run "${LIBEXEC}/update-apply.sh"
  chmod 755 "${GVPN_HOPRD_SNAPSHOTS}"
  [ "${status}" -ne 0 ]
  ! grep -q 'systemctl reboot' "${MOCK_LOG}"
  grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
  [ ! -e "${GVPN_STATE_DIR}/data-owner" ]
}

@test "never releases a staged digest that greenboot rejected before" {
  printf 'sha256:older\nsha256:new\n' > "${GVPN_STATE_DIR}/rejected-digests"
  run "${LIBEXEC}/update-apply.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"sha256:new"*"rejected"* ]]
  ! grep -q 'bootc upgrade' "${MOCK_LOG}"
  ! grep -q 'systemctl stop' "${MOCK_LOG}"
}

@test "an interrupted ownership record still lets the current deployment boot" {
  real_mktemp="$(command -v mktemp)"
  for target in data-owner data-owner-previous; do
    echo "sha256:cur" > "${GVPN_STATE_DIR}/data-owner"
    echo "sha256:older" > "${GVPN_STATE_DIR}/data-owner-previous"
    # The write of ${target} fails as if power were lost before its rename.
    mock_cmd mktemp "[[ \"\$1\" == */${target}.XXXXXX ]] && exit 1; exec ${real_mktemp} \"\$@\""
    run "${LIBEXEC}/update-apply.sh"
    [ "${status}" -ne 0 ]
    ! grep -q 'systemctl reboot' "${MOCK_LOG}"
    run "${LIBEXEC}/data-guard.sh"
    [ "${status}" -eq 0 ] || { echo "after a failed ${target} write: ${output}"; false; }
  done
}
