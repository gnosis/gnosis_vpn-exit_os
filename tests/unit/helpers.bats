#!/usr/bin/env bats
# The shared test helpers: a helper that cannot do its job fails the test
# that called it instead of hanging the suite.

load helpers

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

# hold_lock waits for its background holder to report the lock taken; a holder
# that dies first has to end that wait with its error. The timeout only keeps
# this test from hanging the suite when it does not.
@test "hold_lock fails with the holder's error when the lock cannot be taken" {
  mock_cmd flock 'echo "flock: cannot open lock file: Permission denied" >&2; exit 1'

  run timeout 10 bash -c 'source "$1"; hold_lock "${SANDBOX}/held.lock"' _ \
    "${BATS_TEST_DIRNAME}/helpers.bash"

  [ "${status}" -ne 0 ]
  [ "${status}" -ne 124 ]
  [[ "${output}" == *"${SANDBOX}/held.lock"* ]]
  [[ "${output}" == *"Permission denied"* ]]
}

# flock -c runs its command with ${SHELL}; under direnv that is the login shell,
# such as fish, which cannot run the holder's bash loop.
@test "hold_lock takes the lock whatever the login shell is" {
  mock_cmd fish 'echo "fish: Missing end to balance this for loop" >&2; exit 127'
  export SHELL="${MOCK_BIN}/fish"

  hold_lock "${SANDBOX}/held.lock"
  run flock -n "${SANDBOX}/held.lock" true
  release_lock

  [ "${status}" -eq 1 ]
}
