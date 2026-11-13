# Shared helpers for the bats unit suites.
#
# Scripts under test read every path and tunable from environment variables
# with on-device defaults, so each test points them at a private sandbox and
# replaces external commands with recording mocks on PATH.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
ROOTFS="${REPO_ROOT}/image/rootfs"
LIBEXEC="${ROOTFS}/usr/libexec/gvpn-exit"
SHARE="${ROOTFS}/usr/share/gvpn-exit"

# Create a sandbox with state directories, a mock bin dir on PATH and a call
# log. Exports the GVPN_* overrides understood by lib.sh.
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  MOCK_BIN="${SANDBOX}/bin"
  MOCK_LOG="${SANDBOX}/calls.log"
  mkdir -p "${MOCK_BIN}" "${SANDBOX}/state" "${SANDBOX}/identity" "${SANDBOX}/creds" "${SANDBOX}/etc" "${SANDBOX}/run"
  : > "${MOCK_LOG}"
  export SANDBOX MOCK_BIN MOCK_LOG
  export PATH="${MOCK_BIN}:${PATH}"
  export GVPN_EXIT_DEFAULTS="${SHARE}/exit.env"
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/etc/exit.env"
  export GVPN_STATE_DIR="${SANDBOX}/state"
  export GVPN_IDENTITY_DIR="${SANDBOX}/identity"
  export GVPN_CREDS_DIR="${SANDBOX}/creds"
  export GVPN_RUN_DIR="${SANDBOX}/run"
}

teardown_sandbox() {
  [[ -n "${SANDBOX:-}" ]] && rm -rf "${SANDBOX}"
}

# mock_cmd NAME [BODY]
# Install an executable NAME on PATH that appends "NAME ARGS..." to MOCK_LOG
# and then runs BODY (bash, "$@" available). Default body: exit 0.
mock_cmd() {
  local name="$1" body="${2:-exit 0}"
  cat > "${MOCK_BIN}/${name}" <<EOF
#!/usr/bin/env bash
echo "${name} \$*" >> "${MOCK_LOG}"
${body}
EOF
  chmod +x "${MOCK_BIN}/${name}"
}

# Print the recorded calls, one per line.
calls() {
  cat "${MOCK_LOG}"
}

# Mark the sandboxed device as provisioned.
provision_sandbox() {
  echo "2026-09-24T00:00:00Z" > "${GVPN_IDENTITY_DIR}/provisioned"
}

# seed_capacity DOWN_KBIT UP_KBIT
# Write the uplink measurement cache capacity.sh produces, as a sample from an
# earlier boot. Empty arguments write a cache that records no sample.
seed_capacity() {
  local measured="" attempt=skipped
  if [[ -n "$1" ]]; then
    measured=2026-10-01T03:00:00Z
    attempt=ok
  fi
  cat > "${GVPN_STATE_DIR}/capacity.env" <<EOF
# Uplink sample written by capacity.sh; do not edit.
GVPN_CAPACITY_SCHEMA=1
GVPN_CAPACITY_DOWN_KBIT=$1
GVPN_CAPACITY_UP_KBIT=$2
GVPN_CAPACITY_MEASURED_AT=${measured}
GVPN_CAPACITY_ATTEMPT=${attempt}
GVPN_CAPACITY_ATTEMPT_AT=2026-10-01T03:00:00Z
EOF
}

# Run a function from a sourced script in a clean subshell so the script's
# `set -euo pipefail` never leaks into the bats runner.
# Usage: in_script SCRIPT_PATH FUNCTION [ARGS...]
in_script() {
  bash -c 'source "$1"; shift; "$@"' _ "$@"
}

# write_public_key FILE
# A PEM public key, the shape GVPN_COSIGN_PUB has to have: the tools refuse
# anything else, because cosign takes any file as its --key. Generated when the
# devshell has openssl, otherwise the fixed block below.
write_public_key() {
  if command -v openssl >/dev/null 2>&1 &&
    openssl genpkey -algorithm ed25519 2>/dev/null | openssl pkey -pubout >"$1" 2>/dev/null &&
    [[ -s "$1" ]]; then
    return 0
  fi
  cat >"$1" <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
-----END PUBLIC KEY-----
EOF
}

# hold_lock LOCKFILE
# Take LOCKFILE exclusively in a background process and keep it until
# release_lock, so a test can prove that a mutation waits for the lock instead
# of racing it. The holder gives up after 20 s, so a failing test leaks nothing.
# Its output goes to a file in the sandbox and fd 3, the pipe bats captures test
# output on, is closed: a test that fails before release_lock would otherwise
# make the runner wait for the holder. A holder that dies or has not taken the
# lock within 5 s fails the calling test with its error instead of hanging it.
hold_lock() {
  local lock="$1" ready="${SANDBOX}/lock.held" release="${SANDBOX}/lock.release"
  local log="${SANDBOX}/lock.log" deadline=$((SECONDS + 5))
  rm -f "${ready}" "${release}"
  # bash -c, not flock -c: that runs ${SHELL}, which is fish for some of us.
  flock -x "${lock}" bash -c "
    touch '${ready}'
    for _ in \$(seq 1 400); do
      [[ -e '${release}' ]] && exit 0
      sleep 0.05
    done" >/dev/null 2>"${log}" 3>&- &
  LOCK_HOLDER=$!
  while [[ ! -e "${ready}" ]]; do
    if ! kill -0 "${LOCK_HOLDER}" 2>/dev/null || (( SECONDS >= deadline )); then
      kill "${LOCK_HOLDER}" 2>/dev/null || true
      echo "lock holder could not take ${lock}: $(cat "${log}")" >&2
      return 1
    fi
    sleep 0.02
  done
}

release_lock() {
  touch "${SANDBOX}/lock.release"
  wait "${LOCK_HOLDER}" || true
}
