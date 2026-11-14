#!/usr/bin/env bats
# gvpn-exit-hoprd-migrate is the one-time v4 -> v5 cleanup: it runs the
# bundled v4 binary on the old database and identity, closes the v4 channels,
# moves the old Safe's funds, writes the v5 provisioning file and restarts v5.

load helpers

MIGRATE="${ROOTFS}/usr/bin/gvpn-exit-hoprd-migrate"
OLD_SAFE="0x1111111111111111111111111111111111111111"
OLD_MODULE="0x2222222222222222222222222222222222222222"
NEW_SAFE="0x3333333333333333333333333333333333333333"
NEW_MODULE="0x4444444444444444444444444444444444444444"
NODE="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BLOKLI="https://blokli.example.org"

setup() {
  setup_sandbox
  export GVPN_ASSUME_ROOT=1
  export GVPN_HOPRD_V4_DATA="${SANDBOX}/lib/hoprd"
  export GVPN_HOPRD_DATA="${SANDBOX}/lib/hoprd-v5"
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/lib/hoprd-v5.snapshots"
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/etc/hoprd-v5/hoprd.env.d"
  export GVPN_HOPRD_CFG_TEMPLATE="${SHARE}/hoprd.cfg.yaml"
  export GVPN_HOPRD_V4_ENV_DIR="${SANDBOX}/etc/hoprd/hoprd.env.d"
  export GVPN_CREDS_DIR="${SANDBOX}/creds"
  export GVPN_PROVISIONING_JSON="${SANDBOX}/identity/provisioning.json"
  export GVPN_MIGRATION_MARKER="${SANDBOX}/state/hoprd-v5-migrated"
  export GVPN_V4_HOPRD_BIN="${MOCK_BIN}/hoprd-v4"
  export GVPN_V4_HOPRD_CFG="${SANDBOX}/hoprd-v4.cfg.yaml"
  export GVPN_SYSTEMCTL_BIN="${MOCK_BIN}/systemctl"
  export GVPN_SYSTEMD_CREDS_BIN="${MOCK_BIN}/systemd-creds"
  export GVPN_CURL_BIN="${MOCK_BIN}/curl"
  export GVPN_SLEEP_BIN="${MOCK_BIN}/sleep"
  export GVPN_WORK_PARENT="${SANDBOX}"
  export GVPN_NOW=1790000000
  export GVPN_CHANNEL_CLOSURE_WAIT_S=0
  export GVPN_V4_CHANNEL_SYNC_WAIT_S=0
  export GVPN_CHANNEL_FINALIZE_SETTLE_S=0
  export GVPN_TICKET_REDEEM_WAIT_S=10
  export GVPN_TICKET_POLL_S=5
  export GVPN_V4_CHAIN_READY_WAIT_S=10
  export GVPN_SAFE_OWNER_KEYSTORE="${SANDBOX}/owner.keystore"
  export GVPN_SAFE_OWNER_PASSWORD_FILE="${SANDBOX}/owner.password"
  echo '{}' > "${GVPN_SAFE_OWNER_KEYSTORE}"
  echo 'secret' > "${GVPN_SAFE_OWNER_PASSWORD_FILE}"
  export GVPN_PROVIDER_URL="https://rpc.example.org"
  export GVPN_V4_USER=""
  mkdir -p "${GVPN_HOPRD_V4_DATA}" "${GVPN_CREDS_DIR}" "${GVPN_STATE_DIR}" "${GVPN_IDENTITY_DIR}"
  echo '{"unredeemedValue":"0 wxHOPR"}' > "${SANDBOX}/stats.json"
  : > "${GVPN_V4_HOPRD_CFG}"
  printf 'identity' > "${GVPN_CREDS_DIR}/hopr.id.cred"
  printf 'password' > "${GVPN_CREDS_DIR}/hoprd.password.cred"
  printf 'token' > "${GVPN_CREDS_DIR}/hoprd.api-token.cred"
  printf 'HOPRD_SAFE_ADDRESS=%s\nHOPRD_MODULE_ADDRESS=%s\nHOPRD_BLOKLI_URL=%s\n' \
    "${OLD_SAFE}" "${OLD_MODULE}" "${BLOKLI}" > "${SANDBOX}/old.env"
  mkdir -p "${GVPN_HOPRD_V4_ENV_DIR}"
  cp "${SANDBOX}/old.env" "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env"
  printf '{"node_address":"%s","safe_address":"%s","module_address":"%s"}\n' \
    "${NODE}" "${OLD_SAFE}" "${OLD_MODULE}" > "${GVPN_PROVISIONING_JSON}"
  printf '{"node_address":"%s"}\n' "${NODE}" > "${GVPN_IDENTITY_DIR}/node.json"

  # The mocks that have to take real time run the sleep the sleep mock shadows.
  REAL_SLEEP="$(command -v sleep)"
  export REAL_SLEEP
  mock_cmd hoprd-v4 'exec "${REAL_SLEEP}" 300'
  mock_cmd systemctl 'exit 0'
  mock_cmd sleep 'exit 0'
  mock_cmd systemd-creds '
    out="${!#}"
    case "$*" in
      *hopr.id.cred*) printf "decrypted-identity" > "$out" ;;
      *hoprd.password.cred*) printf "decrypted-password" > "$out" ;;
      *hoprd.api-token.cred*) printf "decrypted-token" > "$out" ;;
      *) exit 1 ;;
    esac'
  mock_cmd curl '
    args="$*"
    case "$args" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"${CHAIN_STATUS:-Ready}\"}}}" ;;
      *"/channels?includingClosed=true"*)
        if [[ -e "${SANDBOX}/deleted" ]]; then
          printf "%s" "{\"outgoing\":[{\"peerAddress\":\"0xaaaa\",\"status\":\"Closed\"}],\"incoming\":[{\"peerAddress\":\"0xbbbb\",\"status\":\"Closed\"}]}"
        else
          printf "%s" "{\"outgoing\":[{\"peerAddress\":\"0xaaaa\",\"status\":\"Open\"}],\"incoming\":[{\"peerAddress\":\"0xbbbb\",\"status\":\"Open\"}]}"
        fi ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *"-X DELETE"*) touch "${SANDBOX}/deleted"; echo "{\"receipt\":\"0x1\"}" ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
  mock_default_cast
}

# The old Safe's balances live in two sandbox files; a send empties the one it
# moves, the way the chain would.
mock_default_cast() {
  echo 7000000000000000000 > "${SANDBOX}/token-balance"
  echo 200000000000000000 > "${SANDBOX}/native-balance"
  # The checksum form comes from the devshell's cast, the version the image
  # ships, unless a test sets CHECKSUM_FORM; every other cast call is mocked.
  REAL_CAST="${REAL_CAST:-$(command -v cast)}"
  export REAL_CAST
  mock_cmd cast '
    [[ -z "${ETH_RPC_URL:-}" ]] || echo "$1 ${ETH_RPC_URL}" >> "${SANDBOX}/cast-rpc-env"
    case "$*" in
      to-check-sum-address\ *) if [[ -n "${CHECKSUM_FORM:-}" ]]; then echo "${CHECKSUM_FORM}"; else "${REAL_CAST}" to-check-sum-address "$2"; fi ;;
      code\ *) echo "${TARGET_CODE-0x6080}" ;;
      call\ 0x3333*"getThreshold()(uint256)"*) [[ -z "${TARGET_NOT_SAFE:-}" ]] || exit 1; echo 1 ;;
      *"getThreshold()(uint256)"*) echo 1 ;;
      *"isOwner(address)(bool)"*) echo true ;;
      *"isModuleEnabled(address)(bool)"*) echo "${MODULE_ENABLED:-true}" ;;
      *"isNode(address)(bool)"*) echo "${IS_NODE:-true}" ;;
      *"wallet address"*) echo 0xowner ;;
      *"nonce()(uint256)"*) echo 7 ;;
      *"balanceOf(address)(uint256)"*) cat "${SANDBOX}/token-balance" ;;
      balance\ 0xowner*) echo "${OWNER_XDAI:-200000000000000000}" ;;
      balance\ *) cat "${SANDBOX}/native-balance" ;;
      *"getTransactionHash"*) echo 0x1111111111111111111111111111111111111111111111111111111111111111 ;;
      *"wallet sign"*) echo "0x$(printf "ab%.0s" {1..64})${SIGNATURE_V:-1b}" ;;
      *"calldata"*) echo 0xdeadbeef ;;
      send\ *)
        if [[ -z "${SEND_MOVES_NOTHING:-}" ]]; then
          case "$*" in
            *0xdeadbeef*) echo 0 > "${SANDBOX}/token-balance" ;;
            *) echo 0 > "${SANDBOX}/native-balance" ;;
          esac
        fi
        echo 0x2222222222222222222222222222222222222222222222222222222222222222 ;;
      *) echo "unexpected cast: $*" >&2; exit 1 ;;
    esac'
}

teardown() {
  teardown_sandbox
}

# refute_logged [GREP_OPTION...] PATTERN: fail when a recorded call matches.
# A bare `! grep` only fails a bats test when it is the test's last command.
refute_logged() {
  if grep -q "$@" "${MOCK_LOG}"; then
    echo "unexpected recorded call matching: $*"
    grep "$@" "${MOCK_LOG}"
    return 1
  fi
}

@test "migrate closes v4 channels, moves the old Safe funds and writes the v5 file" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env")" = "$(printf 'HOPRD_SAFE_ADDRESS=%s\nHOPRD_MODULE_ADDRESS=%s\nHOPRD_BLOKLI_URL=%s' "${NEW_SAFE}" "${NEW_MODULE}" "${BLOKLI}")" ]
  [ "$(stat -c %a "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env")" = "600" ]
  grep -q '^cast calldata transfer(address,uint256) ' "${MOCK_LOG}"
  grep -q "^cast send ${OLD_SAFE} execTransaction" "${MOCK_LOG}"
  [[ "${output}" == *"moved 7000000000000000000 wei wxHOPR"* ]]
  [ "$(jq -r .safe_address "${GVPN_PROVISIONING_JSON}")" = "${NEW_SAFE}" ]
  [ "$(jq -r .module_address "${GVPN_PROVISIONING_JSON}")" = "${NEW_MODULE}" ]
  [ "$(jq -r .migrated_from.safe_address "${GVPN_PROVISIONING_JSON}")" = "${OLD_SAFE}" ]
  [ -s "${GVPN_MIGRATION_MARKER}" ]
  grep -q 'systemctl stop hoprd.service' "${MOCK_LOG}"
  grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
  # Only the outgoing channel holds this node's stake; the incoming one is the
  # counterparty's to close.
  [ "$(grep -c 'X DELETE' "${MOCK_LOG}")" -eq 1 ]
  grep -q 'X DELETE .*/channels/0xaaaa$' "${MOCK_LOG}"
  refute_logged 'direction=incoming'
  # The v4 node ran on the old data and on the decrypted copy in the work dir.
  grep -q "hoprd-v4 .*--data ${GVPN_HOPRD_V4_DATA} .*--identity ${SANDBOX}/gvpn-exit-migrate" "${MOCK_LOG}"
  # The sealed v4 credentials and the old provisioning file are untouched.
  [ "$(cat "${GVPN_CREDS_DIR}/hopr.id.cred")" = "identity" ]
  [ "$(cat "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env")" = "$(cat "${SANDBOX}/old.env")" ]
}

@test "a later configure keeps the Blokli URL the device already uses" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  run "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}"
  [ "${status}" -eq 0 ]
  grep -qx "HOPRD_BLOKLI_URL=${BLOKLI}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
}

@test "the native balance moves only when --native is given" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --native --wait 0
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^cast send ' "${MOCK_LOG}")" -eq 2 ]
  [[ "${output}" == *"moved 200000000000000000 wei xDai"* ]]
}

@test "close-v4-channels does nothing when every channel is already closed" {
  printf '{"outgoing":[],"incoming":[]}' > "${SANDBOX}/closed.json"
  mock_cmd curl '
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"${CHAIN_STATUS:-Ready}\"}}}" ;;
      *"/channels?includingClosed=true"*) cat "${SANDBOX}/closed.json" ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  refute_logged 'X DELETE'
}

@test "an invalid new Safe address fails before anything is stopped or moved" {
  run "${MIGRATE}" migrate --safe-address 0xnot-an-address --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--safe-address"* ]]
  refute_logged 'systemctl stop'
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "missing v4 data fails with a message naming it" {
  rm -rf "${GVPN_HOPRD_V4_DATA}"
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"v4 hoprd data"* ]]
}

@test "a failure after stopping hoprd restarts it and leaves the old config in place" {
  mock_cmd curl '
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"${CHAIN_STATUS:-Ready}\"}}}" ;;
      *"/channels?includingClosed=true"*) echo "{\"outgoing\":[],\"incoming\":[]}" ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *) exit 1 ;;
    esac'
  mock_cmd cast '
    case "$*" in
      to-check-sum-address\ *) echo "$2" ;;
      code\ *) echo 0x6080 ;;
      *"getThreshold()(uint256)"*) echo 1 ;;
      *"isOwner(address)(bool)"*) echo true ;;
      *"isModuleEnabled(address)(bool)"*) echo true ;;
      *"isNode(address)(bool)"*) echo true ;;
      *"wallet address"*) echo 0xowner ;;
      *"nonce()(uint256)"*) echo 7 ;;
      *"balanceOf(address)(uint256)"*) echo 7000000000000000000 ;;
      balance\ *) echo 200000000000000000 ;;
      *"getTransactionHash"*) echo 0x1111111111111111111111111111111111111111111111111111111111111111 ;;
      *"wallet sign"*) echo "0x$(printf "ab%.0s" {1..64})1b" ;;
      *"calldata"*) echo 0xdeadbeef ;;
      send\ *) exit 1 ;;
      *) exit 1 ;;
    esac'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
  [ "$(cat "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env")" = "$(cat "${SANDBOX}/old.env")" ]
}

@test "configure-v5 can run without the v4 data when the Blokli URL is given" {
  rm -rf "${GVPN_HOPRD_V4_DATA}" "${GVPN_CREDS_DIR}"
  run "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" \
    --blokli-url "${BLOKLI}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env")" = "$(printf 'HOPRD_SAFE_ADDRESS=%s\nHOPRD_MODULE_ADDRESS=%s\nHOPRD_BLOKLI_URL=%s' "${NEW_SAFE}" "${NEW_MODULE}" "${BLOKLI}")" ]
}

@test "status shows the v4 fallback before and the v5 file after migration" {
  run "${MIGRATE}" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not configured yet"* ]]
  "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" \
    --blokli-url "${BLOKLI}"
  run "${MIGRATE}" status
  [[ "${output}" == *"${NEW_SAFE}"* ]]
  [[ "${output}" == *"migrated at:"* ]]
}

# Stored as the operator gave them, printed in EIP-55 checksum form (test
# vectors of EIP-55).
@test "status prints the v5 Safe and module in checksum form" {
  "${MIGRATE}" configure-v5 --safe-address 0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359 \
    --module-address 0xDBF03B407C01E7CD3CBEA99509D93F8DDDC8C6FB --blokli-url "${BLOKLI}"
  run "${MIGRATE}" status
  [ "${status}" -eq 0 ]
  grep -qx 'v5 safe: *0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359' <<< "${output}"
  grep -qx 'v5 module: *0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB' <<< "${output}"
  grep -qx 'HOPRD_SAFE_ADDRESS=0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359' "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
}

# A curl mock that walks the outgoing channel through the two closure phases:
# the first DELETE initiates (PendingToClose), a later one finalizes (Closed).
# FINALIZE_NEVER keeps it pending, as before the grace period has passed.
mock_two_phase_curl() {
  mock_cmd curl '
    out="${SANDBOX}/outgoing-status"
    [[ -s "$out" ]] || echo Open > "$out"
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"${CHAIN_STATUS:-Ready}\"}}}" ;;
      *"/channels?includingClosed=true"*)
        printf "{\"outgoing\":[{\"peerAddress\":\"0xaaaa\",\"status\":\"%s\"}],\"incoming\":[]}" "$(< "$out")" ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *"-X DELETE"*)
        if [[ "$(< "$out")" == Open ]]; then
          echo PendingToClose > "$out"
        elif [[ -z "${FINALIZE_NEVER:-}" ]]; then
          echo Closed > "$out"
        else
          exit 22
        fi ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
}

@test "an outgoing channel is initiated, then finalized after the grace period" {
  mock_two_phase_curl
  run "${MIGRATE}" close-v4-channels --wait 300
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'X DELETE .*/channels/0xaaaa' "${MOCK_LOG}")" -eq 2 ]
  grep -qx 'sleep 300' "${MOCK_LOG}"
  [ "$(cat "${SANDBOX}/outgoing-status")" = "Closed" ]
}

@test "a channel still pending closure fails the run, restarts hoprd and moves nothing" {
  mock_two_phase_curl
  export FINALIZE_NEVER=1
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"outgoing 0xaaaa PendingToClose"* ]]
  [[ "${output}" == *"still open or pending closure"* ]]
  grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
  refute_logged '^cast send '
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "a channel that shows up after an empty first listing is still closed" {
  mock_cmd curl '
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"${CHAIN_STATUS:-Ready}\"}}}" ;;
      *"/channels?includingClosed=true"*)
        if [[ -e "${SANDBOX}/deleted" ]]; then
          echo "{\"outgoing\":[{\"peerAddress\":\"0xaaaa\",\"status\":\"Closed\"}],\"incoming\":[]}"
        elif [[ -e "${SANDBOX}/listed" ]]; then
          echo "{\"outgoing\":[{\"peerAddress\":\"0xaaaa\",\"status\":\"Open\"}],\"incoming\":[]}"
        else
          touch "${SANDBOX}/listed"
          echo "{\"outgoing\":[],\"incoming\":[]}"
        fi ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *"-X DELETE"*) touch "${SANDBOX}/deleted" ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  grep -q 'X DELETE .*/channels/0xaaaa' "${MOCK_LOG}"
}

@test "redemption is not waited for when no ticket value is unredeemed" {
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  grep -q '/api/v4/tickets/statistics' "${MOCK_LOG}"
  refute_logged -x 'sleep 5'
}

@test "unredeemed tickets stop the run before any channel is closed" {
  echo '{"unredeemedValue":"2 wxHOPR"}' > "${SANDBOX}/stats.json"
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"2 wxHOPR"* ]]
  [[ "${output}" == *"--forfeit-tickets"* ]]
  # Polled for the whole redemption wait: 10 s in steps of 5 s.
  [ "$(grep -cx 'sleep 5' "${MOCK_LOG}")" -eq 2 ]
  refute_logged 'X DELETE'
  refute_logged '^cast send '
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "--forfeit-tickets closes the channels despite unredeemed tickets" {
  echo '{"unredeemedValue":"2 wxHOPR"}' > "${SANDBOX}/stats.json"
  run "${MIGRATE}" close-v4-channels --wait 0 --forfeit-tickets
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"leaving 2 wxHOPR of v4 tickets unredeemed"* ]]
  [ "$(grep -c 'X DELETE' "${MOCK_LOG}")" -eq 1 ]
}

@test "a multi-owner old Safe is refused before hoprd is stopped" {
  mock_cmd cast 'case "$*" in *"getThreshold()(uint256)"*) echo 2 ;; *) exit 1 ;; esac'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"threshold is 2"* ]]
  refute_logged 'systemctl stop'
}

@test "a key that does not own the old Safe is refused before hoprd is stopped" {
  mock_cmd cast '
    case "$*" in
      *"getThreshold()(uint256)"*) echo 1 ;;
      *"wallet address"*) echo 0xowner ;;
      *"isOwner(address)(bool)"*) echo false ;;
      *) exit 1 ;;
    esac'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"0xowner is not an owner of the old Safe"* ]]
  refute_logged 'systemctl stop'
}

@test "an owner without xDai for gas is refused before hoprd is stopped" {
  export OWNER_XDAI=0
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"has no xDai"* ]]
  refute_logged 'systemctl stop'
}

@test "a signature with recovery id 0 is sent with v 27" {
  export SIGNATURE_V=00
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  grep -qE '^cast send .* 0x(ab){64}1b ' "${MOCK_LOG}"
}

@test "a rerun after the funds moved sends nothing and writes the configuration" {
  touch "${SANDBOX}/deleted"
  echo 0 > "${SANDBOX}/token-balance"
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no wxHOPR left to move"* ]]
  refute_logged 'X DELETE'
  refute_logged '^cast send '
  grep -qx "HOPRD_SAFE_ADDRESS=${NEW_SAFE}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
}

@test "a transfer that leaves the balance in the old Safe fails before v5 is configured" {
  export SEND_MOVES_NOTHING=1
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"still holds 7000000000000000000 wei wxHOPR"* ]]
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "the owner signs from the keystore, so no key is in any cast command line" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  refute_logged -- '--private-key'
  grep -q "^cast wallet address --keystore ${SANDBOX}/owner.keystore --password-file ${SANDBOX}/owner.password" "${MOCK_LOG}"
  grep -q "^cast wallet sign .*--keystore ${SANDBOX}/owner.keystore" "${MOCK_LOG}"
  grep -q "^cast send .*--keystore ${SANDBOX}/owner.keystore" "${MOCK_LOG}"
}

@test "the keystore and password file options override the environment" {
  echo '{}' > "${SANDBOX}/other.keystore"
  echo 'other' > "${SANDBOX}/other.password"
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}" \
    --safe-owner-keystore "${SANDBOX}/other.keystore" --safe-owner-password-file "${SANDBOX}/other.password"
  [ "${status}" -eq 0 ]
  grep -q "^cast send .*--keystore ${SANDBOX}/other.keystore --password-file ${SANDBOX}/other.password" "${MOCK_LOG}"
}

@test "a keystore without its password file is refused" {
  unset GVPN_SAFE_OWNER_PASSWORD_FILE
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--safe-owner-password-file"* ]]
  refute_logged 'systemctl stop'
}

@test "a missing keystore is refused with the option that names it" {
  unset GVPN_SAFE_OWNER_KEYSTORE
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--safe-owner-keystore"* ]]
  refute_logged 'systemctl stop'
}

@test "a raw owner key is not accepted, by option or environment" {
  unset GVPN_SAFE_OWNER_KEYSTORE
  export GVPN_SAFE_OWNER_PRIVATE_KEY="0x1111111111111111111111111111111111111111111111111111111111111111"
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--safe-owner-keystore"* ]]
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}" --safe-owner-key "${GVPN_SAFE_OWNER_PRIVATE_KEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown option --safe-owner-key"* ]]
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}" --safe-owner-key-file "${SANDBOX}/owner.password"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unknown option --safe-owner-key-file"* ]]
  refute_logged -- '--private-key'
}

@test "a target Safe that is not in checksum form is refused before hoprd is stopped" {
  export CHECKSUM_FORM="0x3333333333333333333333333333333333333334"
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"EIP-55"* ]]
  [[ "${output}" == *"cast to-check-sum-address"* ]]
  refute_logged 'systemctl stop'
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"EIP-55"* ]]
  refute_logged 'systemctl stop'
  refute_logged '^cast send '
}

@test "a target without contract code is refused before hoprd is stopped" {
  export TARGET_CODE=0x
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no contract code"* ]]
  refute_logged 'systemctl stop'
  refute_logged '^cast send '
}

@test "a target contract that does not answer as a Safe is refused before hoprd is stopped" {
  export TARGET_NOT_SAFE=1
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not answer as a Safe"* ]]
  refute_logged 'systemctl stop'
  refute_logged '^cast send '
}

@test "an invalid --to fails before hoprd is stopped" {
  run "${MIGRATE}" move-v4-safe-funds --to 0xnot-an-address
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--to"* ]]
  refute_logged 'systemctl stop'
}

@test "reusing the old Safe moves nothing, needs no owner key and completes" {
  # An EIP-55 test vector: provisioned in lower case, given back in upper
  # case, printed in its checksum form.
  local old_lower="0xd1220a0cf47c7b9be7a2e6ba89f429762e7b9adb"
  local old_mixed="0xD1220A0CF47C7B9BE7A2E6BA89F429762E7B9ADB"
  local old_checksummed="0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"
  printf 'HOPRD_SAFE_ADDRESS=%s\nHOPRD_MODULE_ADDRESS=%s\nHOPRD_BLOKLI_URL=%s\n' \
    "${old_lower}" "${OLD_MODULE}" "${BLOKLI}" > "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env"
  unset GVPN_SAFE_OWNER_KEYSTORE GVPN_SAFE_OWNER_PASSWORD_FILE GVPN_PROVIDER_URL
  run "${MIGRATE}" migrate --safe-address "${old_mixed}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${old_checksummed} is the old Safe"* ]]
  refute_logged '^cast send '
  [ "$(grep -c 'X DELETE' "${MOCK_LOG}")" -eq 1 ]
  grep -qx "HOPRD_SAFE_ADDRESS=${old_mixed}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  run "${MIGRATE}" move-v4-safe-funds --to "${old_mixed}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"is the old Safe"* ]]
  refute_logged '^cast send '
}

@test "a listing without open channels is not believed while the chain connector is not ready" {
  printf '{"outgoing":[],"incoming":[]}' > "${SANDBOX}/closed.json"
  mock_cmd curl '
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"Initializing\"}}}" ;;
      *"/channels?includingClosed=true"*) cat "${SANDBOX}/closed.json" ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"chain connector is Initializing"* ]]
  [[ "${output}" == *"close-v4-channels"* ]]
  # Waited for the connector: 10 s in steps of 5 s.
  [ "$(grep -cx 'sleep 5' "${MOCK_LOG}")" -eq 2 ]
  refute_logged '^cast send '
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "open channels are closed even when the chain connector is not ready" {
  export CHAIN_STATUS=Degraded
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'X DELETE' "${MOCK_LOG}")" -eq 1 ]
}

@test "the RPC URL reaches cast through its environment, never a command line" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --native --wait 0
  [ "${status}" -eq 0 ]
  refute_logged 'rpc.example.org'
  refute_logged -- '--rpc-url'
  grep -qx 'call https://rpc.example.org' "${SANDBOX}/cast-rpc-env"
  grep -qx 'balance https://rpc.example.org' "${SANDBOX}/cast-rpc-env"
  grep -qx 'code https://rpc.example.org' "${SANDBOX}/cast-rpc-env"
  grep -qx 'send https://rpc.example.org' "${SANDBOX}/cast-rpc-env"
}

@test "--provider-url-file supplies the RPC URL from a file" {
  unset GVPN_PROVIDER_URL
  echo 'https://keyed.example.org/v1/secret-key' > "${SANDBOX}/rpc.url"
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}" --provider-url-file "${SANDBOX}/rpc.url"
  [ "${status}" -eq 0 ]
  grep -qx 'send https://keyed.example.org/v1/secret-key' "${SANDBOX}/cast-rpc-env"
  refute_logged 'secret-key'
  [[ "${output}" != *"secret-key"* ]]
}

@test "an unreadable --provider-url-file is refused before hoprd is stopped" {
  run "${MIGRATE}" move-v4-safe-funds --to "${NEW_SAFE}" --provider-url-file "${SANDBOX}/missing.url"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot read ${SANDBOX}/missing.url"* ]]
  refute_logged 'systemctl stop'
}

@test "the v4 node runs as the hoprd user on a work directory that user owns" {
  local user uid gid
  user="$(id -un)"
  uid="$(id -u)"
  gid="$(id -g)"
  export GVPN_V4_USER="${user}"
  mock_cmd chown 'exit 0'
  mock_cmd setpriv 'while [[ "$1" == --* ]]; do shift; done; exec "$@"'
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  grep -q "^chown -R ${user} ${SANDBOX}/gvpn-exit-migrate\." "${MOCK_LOG}"
  grep -q "^setpriv --reuid=${uid} --regid=${gid} --init-groups ${MOCK_BIN}/hoprd-v4 " "${MOCK_LOG}"
  grep -q "^hoprd-v4 " "${MOCK_LOG}"
}

@test "an unknown v4 user stops the run before the v4 node starts" {
  export GVPN_V4_USER="gvpn-no-such-user"
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"user gvpn-no-such-user does not exist"* ]]
  refute_logged '^hoprd-v4 '
}

@test "the decrypted password and API token are in no command line" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  refute_logged 'decrypted-password'
  refute_logged 'decrypted-token'
  refute_logged 'decrypted-identity'
  [[ "${output}" != *"decrypted-"* ]]
  # Nothing decrypted is left behind.
  [ -z "$(compgen -G "${SANDBOX}/gvpn-exit-migrate.*")" ]
}

@test "a failed run keeps the v4 node log, a successful one removes it" {
  mock_cmd hoprd-v4 'echo "v4 node says hello"; exec "${REAL_SLEEP}" 300'
  mock_two_phase_curl
  export FINALIZE_NEVER=1
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${GVPN_STATE_DIR}/hoprd-v4-migrate.log"* ]]
  grep -q 'v4 node says hello' "${GVPN_STATE_DIR}/hoprd-v4-migrate.log"
  [ "$(stat -c %a "${GVPN_STATE_DIR}/hoprd-v4-migrate.log")" = "600" ]
  unset FINALIZE_NEVER
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/hoprd-v4-migrate.log" ]
}

@test "a provisioning record that cannot be updated fails without leaving a temporary file" {
  echo 'not json' > "${GVPN_PROVISIONING_JSON}"
  run "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" \
    --blokli-url "${BLOKLI}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot update ${GVPN_PROVISIONING_JSON}"* ]]
  [ -z "$(compgen -G "${GVPN_PROVISIONING_JSON}.*")" ]
  [ "$(cat "${GVPN_PROVISIONING_JSON}")" = "not json" ]
}

# Only outgoing channels hold this node's stake. An incoming channel is the
# counterparty's: it can reopen it at any time, so it must not gate the run.
@test "an incoming channel that stays open is left alone and does not hold up the run" {
  mock_cmd curl '
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"Ready\"}}}" ;;
      *"/channels?includingClosed=true"*)
        echo "{\"outgoing\":[{\"peerAddress\":\"0xaaaa\",\"status\":\"Closed\"}],\"incoming\":[{\"peerAddress\":\"0xbbbb\",\"status\":\"Open\"}]}" ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 300
  [ "${status}" -eq 0 ]
  refute_logged 'X DELETE'
  refute_logged -x 'sleep 300'
  grep -qx "HOPRD_SAFE_ADDRESS=${NEW_SAFE}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
}

@test "a channel listing that cannot be read fails the run without the grace period wait" {
  mock_cmd curl '
    case "$*" in
      *"/startedz") exit 0 ;;
      *"/node/status") echo "{\"components\":{\"chain\":{\"status\":\"Ready\"}}}" ;;
      *"/channels?includingClosed=true"*) exit 22 ;;
      *"/tickets/redeem"*) echo "" ;;
      *"/tickets/statistics"*) cat "${SANDBOX}/stats.json" ;;
      *) echo "unexpected curl: $*" >&2; exit 1 ;;
    esac'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 300
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot read the v4 node's channel listing"* ]]
  # One failed read is retried before the run gives up.
  [ "$(grep -c '/channels?includingClosed=true' "${MOCK_LOG}")" -eq 3 ]
  refute_logged -x 'sleep 300'
  refute_logged '^cast send '
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "--skip-v4-cleanup moves the funds and configures v5 without the v4 node" {
  # Not even the v4 database or the cleanup binary is needed.
  rm -rf "${GVPN_HOPRD_V4_DATA}" "${MOCK_BIN}/hoprd-v4"
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --skip-v4-cleanup
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipping the v4 channel cleanup"* ]]
  [[ "${output}" == *"moved 7000000000000000000 wei wxHOPR"* ]]
  refute_logged '^hoprd-v4 '
  refute_logged '^systemd-creds '
  refute_logged '^curl '
  grep -qx "HOPRD_SAFE_ADDRESS=${NEW_SAFE}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  grep -q 'systemctl start hoprd.service' "${MOCK_LOG}"
}

@test "--v4-start-timeout bounds the wait for the v4 node and the error names the way on" {
  mock_cmd curl 'exit 22'
  run "${MIGRATE}" close-v4-channels --wait 0 --v4-start-timeout 2
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"within 2s"* ]]
  [[ "${output}" == *"--v4-start-timeout"* ]]
  [[ "${output}" == *"--skip-v4-cleanup"* ]]
  # Polled twice a second.
  [ "$(grep -cx 'sleep 0.5' "${MOCK_LOG}")" -eq 4 ]
}

@test "--v4-start-timeout must be a number of seconds" {
  run "${MIGRATE}" close-v4-channels --v4-start-timeout soon
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--v4-start-timeout"* ]]
  refute_logged 'systemctl stop'
}

@test "a v4 node that exits at once fails the run and the error names the way on" {
  mock_cmd hoprd-v4 'echo "blokli unreachable"; exit 1'
  mock_cmd curl 'exit 22'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--skip-v4-cleanup"* ]]
  [[ "${output}" == *"--v4-blokli-url"* ]]
  refute_logged '^cast send '
}

@test "--v4-blokli-url reaches only the v4 node" {
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0 \
    --v4-blokli-url https://old-blokli.example.org
  [ "${status}" -eq 0 ]
  grep -q '^hoprd-v4 .*--blokliUrl https://old-blokli.example.org$' "${MOCK_LOG}"
  grep -qx "HOPRD_BLOKLI_URL=${BLOKLI}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  [ "$(cat "${GVPN_HOPRD_V4_ENV_DIR}/10-provisioned.env")" = "$(cat "${SANDBOX}/old.env")" ]
}

@test "a module that is not enabled on the new Safe is refused before hoprd is stopped" {
  export MODULE_ENABLED=false
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"is not enabled on the Safe"* ]]
  grep -q "^cast call ${NEW_SAFE} isModuleEnabled(address)(bool) ${NEW_MODULE}$" "${MOCK_LOG}"
  refute_logged 'systemctl stop'
  refute_logged '^cast send '
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "a module that does not include this node is refused before hoprd is stopped" {
  export IS_NODE=false
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not include this node"* ]]
  grep -q "^cast call ${NEW_MODULE} isNode(address)(bool) ${NODE}$" "${MOCK_LOG}"
  refute_logged 'systemctl stop'
  refute_logged '^cast send '
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "configure-v5 checks the Safe and module pair when it is given an RPC URL" {
  export IS_NODE=false
  echo 'https://rpc.example.org' > "${SANDBOX}/rpc.url"
  unset GVPN_PROVIDER_URL
  run "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" \
    --provider-url-file "${SANDBOX}/rpc.url"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not include this node"* ]]
  refute_logged 'systemctl stop'
  [ ! -e "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]
}

@test "configure-v5 without an RPC URL writes the configuration and says the pair is unchecked" {
  unset GVPN_PROVIDER_URL
  export IS_NODE=false
  run "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not checked"* ]]
  refute_logged '^cast call '
  grep -qx "HOPRD_SAFE_ADDRESS=${NEW_SAFE}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
}

@test "hoprd that does not stay up with the v5 configuration fails the run" {
  mock_cmd systemctl '
    case "$*" in
      *is-active*) exit 3 ;;
    esac
    exit 0'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"did not stay up"* ]]
  [[ "${output}" == *"configure-v5"* ]]
  [[ "${output}" != *"Migration complete"* ]]
  grep -qx 'sleep 60' "${MOCK_LOG}"
  # The configuration is written: the funds have moved, so it is corrected, not undone.
  grep -qx "HOPRD_SAFE_ADDRESS=${NEW_SAFE}" "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
}

@test "hoprd that systemd restarted during the watch fails the run" {
  mock_cmd systemctl '
    case "$*" in
      *NRestarts*)
        count="$(cat "${SANDBOX}/restarts" 2>/dev/null || echo 0)"
        echo "${count}"
        echo $(( count + 1 )) > "${SANDBOX}/restarts" ;;
    esac
    exit 0'
  run "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"did not stay up"* ]]
}

@test "the helper holds the OS update lock while hoprd is stopped" {
  mock_cmd systemctl '
    if [[ "$1" == stop ]]; then
      if flock -n "${GVPN_RUN_DIR}/update.lock" true; then
        echo free > "${SANDBOX}/lock-state"
      else
        echo held > "${SANDBOX}/lock-state"
      fi
    fi
    exit 0'
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/lock-state")" = "held" ]
  # Released with the run, so the next update or migration is not blocked.
  flock -n "${GVPN_RUN_DIR}/update.lock" true
}

# hold_lock paces its holder with the sleep on PATH, which must be the real one.
unmock_sleep() {
  rm -f "${MOCK_BIN}/sleep"
  export GVPN_SLEEP_BIN="${REAL_SLEEP}"
}

@test "a run that cannot take the OS update lock stops before anything is touched" {
  export GVPN_MIGRATE_LOCK_WAIT_S=1
  unmock_sleep
  hold_lock "${GVPN_RUN_DIR}/update.lock"
  run "${MIGRATE}" migrate --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}" --wait 0
  release_lock
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${GVPN_RUN_DIR}/update.lock"* ]]
  refute_logged 'systemctl stop'
  refute_logged '^hoprd-v4 '
}

@test "the v4 node does not inherit the OS update lock" {
  mock_cmd hoprd-v4 '
    if { true >&9; } 2>/dev/null; then echo open > "${SANDBOX}/v4-fd9"; else echo closed > "${SANDBOX}/v4-fd9"; fi
    exec "${REAL_SLEEP}" 300'
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/v4-fd9")" = "closed" ]
}

@test "status does not wait for the OS update lock" {
  export GVPN_MIGRATE_LOCK_WAIT_S=1
  unmock_sleep
  hold_lock "${GVPN_RUN_DIR}/update.lock"
  run "${MIGRATE}" status
  release_lock
  [ "${status}" -eq 0 ]
}

@test "a v4 node that ignores the stop request is killed after the stop timeout" {
  export GVPN_V4_STOP_TIMEOUT_S=1
  mock_cmd hoprd-v4 '
    echo $$ > "${SANDBOX}/v4.pid"
    trap "" TERM
    while :; do "${REAL_SLEEP}" 0.1; done'
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"did not stop within 1s"* ]]
  ! kill -0 "$(cat "${SANDBOX}/v4.pid")" 2>/dev/null
}

# A dropped SSH session or a shutdown ends the helper with a signal. bash runs
# the exit handler with the status of the last command, which is 0.
@test "an interrupted run keeps the v4 node log, stops the node and leaves nothing decrypted" {
  mock_cmd hoprd-v4 'echo $$ > "${SANDBOX}/v4.pid"; echo "v4 node says hello"; exec "${REAL_SLEEP}" 300'
  mock_cmd sleep '
    if [[ "$1" == 300 ]]; then
      echo $$ > "${SANDBOX}/wait.pid"
      exec "${REAL_SLEEP}" 30
    fi
    exit 0'
  mock_two_phase_curl
  "${MIGRATE}" close-v4-channels --wait 300 > "${SANDBOX}/run.out" 2>&1 3>&- &
  local helper=$! deadline=$(( SECONDS + 10 ))
  until [[ -s "${SANDBOX}/wait.pid" ]]; do
    (( SECONDS < deadline )) || { cat "${SANDBOX}/run.out"; false; }
    "${REAL_SLEEP}" 0.05
  done
  kill -TERM "${helper}"
  local status=0
  wait "${helper}" || status=$?
  kill "$(cat "${SANDBOX}/wait.pid")" 2>/dev/null || true
  [ "${status}" -eq 143 ]
  grep -q 'v4 node says hello' "${GVPN_STATE_DIR}/hoprd-v4-migrate.log"
  ! kill -0 "$(cat "${SANDBOX}/v4.pid")" 2>/dev/null
  [ -z "$(compgen -G "${SANDBOX}/gvpn-exit-migrate.*")" ]
}

@test "a failed run on a device without the v5 configuration says hoprd stays stopped" {
  mock_two_phase_curl
  export FINALIZE_NEVER=1
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"hoprd.service stays stopped"* ]]
  [[ "${output}" != *"hoprd.service restarted"* ]]
}

@test "a failed run on a migrated device restarts hoprd and says so" {
  "${MIGRATE}" configure-v5 --safe-address "${NEW_SAFE}" --module-address "${NEW_MODULE}"
  mock_two_phase_curl
  export FINALIZE_NEVER=1
  run "${MIGRATE}" close-v4-channels --wait 0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"hoprd.service restarted"* ]]
}
