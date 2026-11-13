#!/usr/bin/env bash
# ExecStartPre of gnosisvpn-server.service.
#
# Renders two files into the service's RuntimeDirectory (tmpfs):
# - wggvpn.conf: the [Interface] section from wggvpn.conf.in with the server
#   key from the sealed wg.key credential, mode 0600. The key never exists in
#   plaintext on persistent storage.
# - config.toml: gnosis_vpn-server config, with the client pool derived from
#   exit.env so the pool and the shaping classes always agree.
#
# Peers are not persisted across service restarts; clients re-register.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

GVPN_SERVER_RUN_DIR="${GVPN_SERVER_RUN_DIR:-/run/gnosisvpn-server}"
GVPN_WG_TEMPLATE="${GVPN_WG_TEMPLATE:-/usr/share/gvpn-exit/wggvpn.conf.in}"
WG_CONF="${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
SERVER_CONF="${GVPN_SERVER_RUN_DIR}/config.toml"

if [[ -z "${CREDENTIALS_DIRECTORY:-}" || ! -s "${CREDENTIALS_DIRECTORY}/wg.key" ]]; then
  log "credential wg.key is missing; run via gnosisvpn-server.service"
  exit 1
fi

private_key="$(< "${CREDENTIALS_DIRECTORY}/wg.key")"
# A WireGuard key is 32 bytes, base64: 43 characters plus one '=' of padding.
if [[ ! "${private_key}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  log "credential wg.key does not hold a WireGuard private key"
  exit 1
fi

if ! peer_octet_range_ok "${GVPN_PEER_MIN_OCTET}" "${GVPN_PEER_MAX_OCTET}"; then
  log "peer octet range ${GVPN_PEER_MIN_OCTET}..${GVPN_PEER_MAX_OCTET} must lie within 2..254"
  exit 1
fi

umask 077

wg_conf="$(< "${GVPN_WG_TEMPLATE}")"
wg_conf="${wg_conf//@WIREGUARD_ADDRESS@/${WIREGUARD_ADDRESS}}"
wg_conf="${wg_conf//@WIREGUARD_PORT@/${WIREGUARD_PORT}}"
wg_conf="${wg_conf//@WIREGUARD_MTU@/${WIREGUARD_MTU}}"
wg_conf="${wg_conf//@PRIVATE_KEY@/${private_key}}"
printf '%s\n' "${wg_conf}" > "${WG_CONF}.tmp"
chmod 0600 "${WG_CONF}.tmp"
mv -f "${WG_CONF}.tmp" "${WG_CONF}"

cat > "${SERVER_CONF}.tmp" <<EOF
allowed_client_ips = { start = "${GVPN_PEER_SUBNET_PREFIX}.${GVPN_PEER_MIN_OCTET}", end = "${GVPN_PEER_SUBNET_PREFIX}.${GVPN_PEER_MAX_OCTET}" }
wireguard_config_path = "${WG_CONF}"
endpoint = "${GVPN_SERVER_ENDPOINT}"
client_handshake_timeout_s = ${GVPN_CLIENT_HANDSHAKE_TIMEOUT_S}
client_cleanup_interval_s = ${GVPN_CLIENT_CLEANUP_INTERVAL_S}
EOF
mv -f "${SERVER_CONF}.tmp" "${SERVER_CONF}"

log "rendered ${WG_CONF} and ${SERVER_CONF}"
