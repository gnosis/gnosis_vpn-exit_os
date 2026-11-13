#!/usr/bin/env bats
# The build-time blocklist snapshot fetches the same feeds the device does, so
# its request is bound to https the same way.

load helpers

SCRIPT="${REPO_ROOT}/image/build/snapshot-blocklist.sh"

setup() {
  setup_sandbox
  OUTPUT="${SANDBOX}/blocklist.cidr"
}

teardown() {
  teardown_sandbox
}

# A feed of 1000 entries clears the minimum the device enforces and stays far
# below the coverage ceiling, so the snapshot reaches the end of the script.
@test "the snapshot fetch never leaves https, not even on a redirect" {
  mock_cmd curl 'i=1
while (( i <= 1000 )); do
  printf "1.0.%d.%d\n" $(( i / 256 )) $(( i % 256 ))
  i=$(( i + 1 ))
done'

  run bash "${SCRIPT}" "${ROOTFS}" "${OUTPUT}"

  [ "${status}" -eq 0 ]
  grep -q -- '--proto =https --proto-redir =https' "${MOCK_LOG}"
  [ "$(wc -l < "${OUTPUT}")" -eq 1000 ]
}
