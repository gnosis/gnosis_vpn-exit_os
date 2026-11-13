#!/usr/bin/env bats
# build-recovery.sh builds the stick's Unified Kernel Image inside the pinned
# base image. Appliances are x86_64 and the stick boots BOOTX64.EFI, so the
# build must use the amd64 base image whatever the build host's architecture.

load helpers

setup() {
  setup_sandbox
  export GVPN_RECOVERY_OUTPUT="${SANDBOX}/recovery"
  mock_cmd podman
  mock_cmd ls
}

teardown() {
  teardown_sandbox
}

@test "the build runs the amd64 base image, also on an arm64 host" {
  run "${REPO_ROOT}/tools/build-recovery.sh"
  [ "${status}" -eq 0 ]
  grep -q '^podman run .*--platform linux/amd64 ' "${MOCK_LOG}"
}

# A build that installs packages into its own container filesystem does not
# need root on the host or the host's container storage.
@test "the build runs unprivileged and leaves the host storage alone" {
  run "${REPO_ROOT}/tools/build-recovery.sh"
  [ "${status}" -eq 0 ]
  run grep -q -e '--privileged' -e '/var/lib/containers/storage' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  grep -q -- "-v ${REPO_ROOT}:/src:ro " "${MOCK_LOG}"
  grep -q -- "-v ${GVPN_RECOVERY_OUTPUT}:/out " "${MOCK_LOG}"
}
