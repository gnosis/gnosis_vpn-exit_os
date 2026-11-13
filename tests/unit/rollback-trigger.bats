#!/usr/bin/env bats
# rollback-trigger.sh is the ExecStop of greenboot-set-rollback-trigger.service
# (shipped drop-in). greenboot-rs arms its rollback trigger from any staged
# deployment, but a download-only update is only released by update-apply.sh
# inside the maintenance window: arming it would turn an ordinary reboot in
# between into a rollback to the previous deployment.

load helpers

setup() {
  setup_sandbox
  SCRIPT="${LIBEXEC}/rollback-trigger.sh"
  mock_cmd greenboot
  export GVPN_GREENBOOT_BIN="${MOCK_BIN}/greenboot"
}

teardown() {
  teardown_sandbox
}

# staged_status DOWNLOAD_ONLY: bootc status with one staged deployment.
staged_status() {
  mock_cmd bootc "echo '{\"status\":{\"staged\":{\"image\":{\"imageDigest\":\"sha256:new\"},\"downloadOnly\":$1},\"booted\":{\"image\":{\"imageDigest\":\"sha256:cur\"}}}}'"
}

@test "a download-only staged update does not arm the rollback trigger" {
  staged_status true

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *download-only* ]]
  ! grep -q '^greenboot ' "${MOCK_LOG}"
}

@test "a released staged update arms the rollback trigger" {
  staged_status false

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'greenboot set-rollback-trigger' "${MOCK_LOG}"
}

@test "nothing staged arms the trigger and leaves the bookkeeping to greenboot" {
  mock_cmd bootc "echo '{\"status\":{\"staged\":null,\"booted\":{\"image\":{\"imageDigest\":\"sha256:cur\"}}}}'"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'greenboot set-rollback-trigger' "${MOCK_LOG}"
}

@test "an unreadable bootc status arms the trigger" {
  # Never lose a real rollback trigger over a failed status read.
  mock_cmd bootc 'exit 1'

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'greenboot set-rollback-trigger' "${MOCK_LOG}"
}
