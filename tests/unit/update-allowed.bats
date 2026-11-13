#!/usr/bin/env bats
# update-allowed.sh is the ExecCondition of gvpn-exit-update-stage.service: it
# stops a digest that greenboot already rejected from being staged again.

load helpers

setup() {
  setup_sandbox
  mock_cmd bootc 'echo "{\"spec\":{\"image\":{\"image\":\"registry.example/gvpn-exit-os:stable\",\"transport\":\"registry\"}}}"'
  mock_cmd skopeo 'echo sha256:candidate'
}

teardown() {
  teardown_sandbox
}

@test "allows a digest that was never rejected" {
  printf 'sha256:bad1\nsha256:bad2\n' > "${GVPN_STATE_DIR}/rejected-digests"
  run "${LIBEXEC}/update-allowed.sh"
  [ "${status}" -eq 0 ]
}

@test "allows staging when nothing was ever rejected" {
  run "${LIBEXEC}/update-allowed.sh"
  [ "${status}" -eq 0 ]
}

@test "skips a digest that was rejected before" {
  printf 'sha256:bad1\nsha256:candidate\n' > "${GVPN_STATE_DIR}/rejected-digests"
  run "${LIBEXEC}/update-allowed.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"sha256:candidate"* ]]
}

@test "resolves the tracked tag through the registry" {
  run "${LIBEXEC}/update-allowed.sh"
  grep -q 'skopeo inspect .*docker://registry.example/gvpn-exit-os:stable' "${MOCK_LOG}"
}

@test "skips when the channel digest cannot be resolved" {
  mock_cmd skopeo 'exit 1'
  run "${LIBEXEC}/update-allowed.sh"
  [ "${status}" -eq 1 ]
}

@test "skips when the system tracks no image" {
  mock_cmd bootc 'echo "{\"spec\":{\"image\":null}}"'
  run "${LIBEXEC}/update-allowed.sh"
  [ "${status}" -eq 1 ]
}
