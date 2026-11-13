#!/usr/bin/env bash
# gvpn-exit-loopback-alias.service: assign (up) or remove (down) the session
# target address on the loopback interface.
#
# The GnosisVPN client defaults its bridge and WireGuard session targets to
# 172.30.0.1, the session target address built into the client. Keeping that
# address on lo means hoprd reaches gnosis_vpn-server and wggvpn there while
# the address stays local: no LAN route is involved, and the firewall never
# has to allow it on lan0.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

GVPN_SESSION_TARGET_ADDRESS="${GVPN_SESSION_TARGET_ADDRESS:-172.30.0.1/32}"
GVPN_LOOPBACK_IFACE="${GVPN_LOOPBACK_IFACE:-lo}"

up() {
  ip addr replace "${GVPN_SESSION_TARGET_ADDRESS}" dev "${GVPN_LOOPBACK_IFACE}"
}

down() {
  ip addr del "${GVPN_SESSION_TARGET_ADDRESS}" dev "${GVPN_LOOPBACK_IFACE}" 2>/dev/null || true
}

main() {
  case "${1:-}" in
    up) up ;;
    down) down ;;
    *) echo "usage: ${0} up|down" >&2; exit 64 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
