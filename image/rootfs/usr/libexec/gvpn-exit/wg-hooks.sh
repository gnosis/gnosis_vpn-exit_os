#!/usr/bin/env bash
# wg-quick PostUp/PreDown hooks for wggvpn (`wg-hooks.sh up|down`).
#
# Installs the dynamic part of the firewall on top of the static ruleset from
# gvpn-exit-firewall.service. The guards go in before anything that forwards
# and come out after it, so no intermediate state, and no hook that fails half
# way, lets VPN clients reach private ranges:
#
#   1. ensure the blocklist ipset exists (the refresh timer fills it)
#   1a. INPUT accept the client's tunnel-verification ping to the server address
#       (head), from the pool the server hands out; the static ruleset drops
#       everything else from wggvpn
#   2. FORWARD drop clients -> blocklisted destinations (head)
#   3. FORWARD drop blocklisted sources -> clients (head)
#   4. FORWARD jump to GVPN_PRIVATE for wggvpn: LAN/host isolation (head).
#      Redundant with the static jump on purpose, so isolation holds even if
#      the static ruleset is edited wrongly. Tagged with a comment so deleting
#      it can never match, and remove, the identical static jump.
#   5. TCP MSS clamp on both sides of the tunnel (mangle)
#   6. per-peer shaping (gvpn-peer-shaping.sh)
#   7. NAT: MASQUERADE the client pool out of the LAN uplink
#   8. FORWARD accept wggvpn -> uplink, appended behind every isolation rule
#
# Resulting filter FORWARD: 4, 3, 2, the static rules, 8; the mangle FORWARD
# chain holds the two clamps. `down` removes 8..2 and the clamps in reverse
# order. The ipset is left in the kernel so the refresh timer keeps working
# across interface restarts.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

WG_IF="wggvpn"
UPLINK="${NETWORK_INTERFACE}"
IPSET_NAME="${GVPN_BLOCKLIST_IPSET_NAME}"
GVPN_SHAPING_BIN="${GVPN_SHAPING_BIN:-/usr/libexec/gvpn-exit/gvpn-peer-shaping.sh}"
# MSS for TCP crossing the tunnel: the tunnel MTU minus the IPv4 and TCP
# headers. A peer that advertises more (a host or container behind the client
# whose stack sizes segments from its own 1500-byte interface) would otherwise
# pull segments out of the internet that do not fit into wggvpn; those are
# dropped with DF set, and a server that ignores the resulting ICMP
# frag-needed stalls the connection. TCPMSS never raises an advertised value,
# so clients that already announce the tunnel MSS are unaffected.
MSS=$((WIREGUARD_MTU - 40))

# The client pings the server's tunnel address to verify the connection
# (`connection.ping`, default 10.128.0.1) before reporting it established.
# Both ends come from exit.env, so a changed WIREGUARD_CIDR or
# WIREGUARD_ADDRESS keeps the allowance in step with the rendered interface.
PING_RULE=(INPUT -i "${WG_IF}" -s "${WIREGUARD_CIDR}" -d "${WIREGUARD_ADDRESS}" \
  -p icmp -m icmp --icmp-type 8 -j ACCEPT)
NAT_RULE=(POSTROUTING -s "${WIREGUARD_CIDR}" -o "${UPLINK}" -j MASQUERADE)
ACCEPT_RULE=(FORWARD -i "${WG_IF}" -o "${UPLINK}" -j ACCEPT)
BLOCK_DST_RULE=(FORWARD -i "${WG_IF}" -m set --match-set "${IPSET_NAME}" dst -j DROP)
BLOCK_SRC_RULE=(FORWARD -o "${WG_IF}" -m set --match-set "${IPSET_NAME}" src -j DROP)
PRIVATE_RULE=(FORWARD -i "${WG_IF}" -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE)
# SYN,RST SYN also matches SYN-ACK, so the clamp covers the MSS each side
# announces to the other.
MSS_IN_RULE=(FORWARD -i "${WG_IF}" -p tcp --tcp-flags 'SYN,RST' SYN -j TCPMSS --set-mss "${MSS}")
MSS_OUT_RULE=(FORWARD -o "${WG_IF}" -p tcp --tcp-flags 'SYN,RST' SYN -j TCPMSS --set-mss "${MSS}")

up() {
  # wg-quick skips PreDown when gnosis_vpn-server is killed hard; start from a
  # clean slate so a restart never stacks duplicate rules.
  down 2>/dev/null

  ipset create "${IPSET_NAME}" hash:net family inet maxelem "${GVPN_BLOCKLIST_MAXELEM}" -exist
  # Ahead of the static "drop everything from wggvpn" rule.
  iptables -I "${PING_RULE[@]}"
  iptables -I "${BLOCK_DST_RULE[@]}"
  iptables -I "${BLOCK_SRC_RULE[@]}"
  iptables -I "${PRIVATE_RULE[@]}"
  iptables -t mangle -A "${MSS_IN_RULE[@]}"
  iptables -t mangle -A "${MSS_OUT_RULE[@]}"
  "${GVPN_SHAPING_BIN}" up
  iptables -t nat -A "${NAT_RULE[@]}"
  iptables -A "${ACCEPT_RULE[@]}"
}

down() {
  iptables -D "${ACCEPT_RULE[@]}" || true
  iptables -t nat -D "${NAT_RULE[@]}" || true
  "${GVPN_SHAPING_BIN}" down || true
  iptables -t mangle -D "${MSS_OUT_RULE[@]}" || true
  iptables -t mangle -D "${MSS_IN_RULE[@]}" || true
  iptables -D "${PRIVATE_RULE[@]}" || true
  iptables -D "${BLOCK_SRC_RULE[@]}" || true
  iptables -D "${BLOCK_DST_RULE[@]}" || true
  iptables -D "${PING_RULE[@]}" || true
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
