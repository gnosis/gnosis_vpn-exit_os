#!/usr/bin/env bats
# hoprd-run.sh turns the value credentials (password, API token) delivered by
# LoadCredentialEncrypted= into the env vars hoprd reads, copies the sealed
# identity to the v5 path before hoprd opens it, then execs hoprd.

load helpers

setup() {
  setup_sandbox
  export CREDENTIALS_DIRECTORY="${SANDBOX}/credentials"
  export RUNTIME_DIRECTORY="${SANDBOX}/run/hoprd"
  export GVPN_HOPRD_CFG_TEMPLATE="${SHARE}/hoprd.cfg.yaml"
  export HOPRD_BLOKLI_URL="https://blokli.example.org"
  mkdir -p "${CREDENTIALS_DIRECTORY}" "${RUNTIME_DIRECTORY}"
  printf 's3cr3t-password' > "${CREDENTIALS_DIRECTORY}/hoprd.password"
  printf 'api-token-123\n' > "${CREDENTIALS_DIRECTORY}/hoprd.api-token"
  printf 'identity-bytes' > "${CREDENTIALS_DIRECTORY}/hopr.id"
  # stub hoprd: print what it received
  export HOPRD_BIN="${MOCK_BIN}/hoprd"
  mock_cmd hoprd 'echo "PASSWORD=${HOPRD_PASSWORD}"; echo "TOKEN=${HOPRD_API_TOKEN}"; echo "IDENTITY=${HOPRD_IDENTITY}"; echo "EMPTY=${HOPRD_IDENTITY:+no}"; echo "ARGS=$*"'
}

teardown() {
  teardown_sandbox
}

@test "exports the password and API token from the credentials directory" {
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PASSWORD=s3cr3t-password"* ]]
  [[ "${output}" == *"TOKEN=api-token-123"* ]]
}

@test "strips the trailing newline from credential values" {
  run "${LIBEXEC}/hoprd-run.sh"
  [[ "${output}" == *$'TOKEN=api-token-123\nIDENTITY='* ]]
}

@test "passes all arguments through to hoprd" {
  run "${LIBEXEC}/hoprd-run.sh" --apiPort 3002
  [[ "${output}" == *"ARGS=--configurationFilePath ${RUNTIME_DIRECTORY}/hoprd.cfg.yaml --apiPort 3002"* ]]
}

@test "renders the current template with the provisioned Blokli URL on every start" {
  export HOPRD_BLOKLI_URL="https://blokli-fallback.example"
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ARGS=--configurationFilePath ${RUNTIME_DIRECTORY}/hoprd.cfg.yaml"* ]]
  [ "$(grep -c 'blokli_url: https://blokli-fallback.example' "${RUNTIME_DIRECTORY}/hoprd.cfg.yaml")" -eq 2 ]
  grep -q '^    - Pix:$' "${RUNTIME_DIRECTORY}/hoprd.cfg.yaml"
}

@test "fails instead of starting against the placeholder Blokli URL" {
  unset HOPRD_BLOKLI_URL
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"HOPRD_BLOKLI_URL is missing or invalid"* ]]
  ! grep -q '^hoprd' "${MOCK_LOG}"
}

@test "gives hoprd the identity under the v5 path, not the sealed v4 credential" {
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"IDENTITY=${RUNTIME_DIRECTORY}/hopr-v5.id"* ]]
  [ "$(cat "${RUNTIME_DIRECTORY}/hopr-v5.id")" = "identity-bytes" ]
  [ "$(stat -c %a "${RUNTIME_DIRECTORY}/hopr-v5.id")" = "600" ]
  # The source the systemd credential delivered is never modified.
  [ "$(cat "${CREDENTIALS_DIRECTORY}/hopr.id")" = "identity-bytes" ]
}

@test "fails without a credentials directory" {
  unset CREDENTIALS_DIRECTORY
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -ne 0 ]
  ! grep -q '^hoprd' "${MOCK_LOG}"
}

@test "fails without a runtime directory" {
  unset RUNTIME_DIRECTORY
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"RUNTIME_DIRECTORY"* ]]
  ! grep -q '^hoprd' "${MOCK_LOG}"
}

@test "fails when a credential is missing or empty" {
  : > "${CREDENTIALS_DIRECTORY}/hoprd.password"
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"hoprd.password"* ]]
  ! grep -q '^hoprd' "${MOCK_LOG}"
}

@test "fails when the identity credential is missing" {
  rm "${CREDENTIALS_DIRECTORY}/hopr.id"
  run "${LIBEXEC}/hoprd-run.sh"
  [ "${status}" -ne 0 ]
  ! grep -q '^hoprd' "${MOCK_LOG}"
}
