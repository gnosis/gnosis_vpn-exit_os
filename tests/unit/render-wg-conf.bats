#!/usr/bin/env bats
# render-wg-conf.sh renders the gnosis_vpn-server config and the wggvpn
# WireGuard config into /run from exit.env and the sealed wg.key credential.

load helpers

KEY="aGVsbG8gd29ybGQgdGhpcyBpcyAzMiBieXRlcyBrZXk="

setup() {
  setup_sandbox
  export CREDENTIALS_DIRECTORY="${SANDBOX}/credentials"
  export GVPN_SERVER_RUN_DIR="${SANDBOX}/run/gnosisvpn-server"
  export GVPN_WG_TEMPLATE="${SHARE}/wggvpn.conf.in"
  mkdir -p "${CREDENTIALS_DIRECTORY}" "${GVPN_SERVER_RUN_DIR}"
  printf '%s\n' "${KEY}" > "${CREDENTIALS_DIRECTORY}/wg.key"
}

teardown() {
  teardown_sandbox
}

@test "renders the WireGuard config with the key from the credential" {
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -eq 0 ]
  conf="${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
  grep -qx "PrivateKey = ${KEY}" "${conf}"
  grep -qx "Address = 10.128.0.1/32" "${conf}"
  grep -qx "ListenPort = 51820" "${conf}"
  grep -qx "MTU = 1420" "${conf}"
}

@test "the WireGuard config calls the ordered hooks on up and down" {
  run "${LIBEXEC}/render-wg-conf.sh"
  conf="${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
  grep -qx "PostUp = /usr/libexec/gvpn-exit/wg-hooks.sh up" "${conf}"
  grep -qx "PreDown = /usr/libexec/gvpn-exit/wg-hooks.sh down" "${conf}"
}

@test "leaves no template placeholder behind" {
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -eq 0 ]
  ! grep -q '@[A-Z_]*@' "${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
}

@test "the WireGuard config is mode 0600" {
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "$(stat -c %a "${GVPN_SERVER_RUN_DIR}/wggvpn.conf")" = "600" ]
}

@test "renders the server config pointing at the /run WireGuard config" {
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -eq 0 ]
  conf="${GVPN_SERVER_RUN_DIR}/config.toml"
  grep -qx "wireguard_config_path = \"${GVPN_SERVER_RUN_DIR}/wggvpn.conf\"" "${conf}"
  grep -qx 'endpoint = "172.30.0.1:8000"' "${conf}"
  grep -qx 'client_handshake_timeout_s = 300' "${conf}"
  grep -qx 'client_cleanup_interval_s = 180' "${conf}"
}

@test "the client pool follows the peer octet bounds" {
  echo "GVPN_PEER_MAX_OCTET=9" > "${GVPN_EXIT_OVERRIDES}"
  run "${LIBEXEC}/render-wg-conf.sh"
  grep -qx 'allowed_client_ips = { start = "10.128.0.2", end = "10.128.0.9" }' "${GVPN_SERVER_RUN_DIR}/config.toml"
}

@test "the client pool follows the measured capacity" {
  seed_capacity 200000 200000
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'allowed_client_ips = { start = "10.128.0.2", end = "10.128.0.11" }' \
    "${GVPN_SERVER_RUN_DIR}/config.toml"
}

@test "the client pool falls back to one slot without a measurement" {
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'allowed_client_ips = { start = "10.128.0.2", end = "10.128.0.2" }' \
    "${GVPN_SERVER_RUN_DIR}/config.toml"
}

@test "fails without the wg.key credential and writes nothing" {
  rm "${CREDENTIALS_DIRECTORY}/wg.key"
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -ne 0 ]
  [ ! -e "${GVPN_SERVER_RUN_DIR}/wggvpn.conf" ]
}

@test "rejects a malformed key" {
  printf 'not-a-wireguard-key\n' > "${CREDENTIALS_DIRECTORY}/wg.key"
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"wg.key"* ]]
  [ ! -e "${GVPN_SERVER_RUN_DIR}/wggvpn.conf" ]
}

@test "rejects a peer range outside 2..254" {
  echo "GVPN_PEER_MAX_OCTET=255" > "${GVPN_EXIT_OVERRIDES}"
  run "${LIBEXEC}/render-wg-conf.sh"
  [ "${status}" -ne 0 ]
}
