#!/usr/bin/env bash
# Per-peer traffic shaping for the GnosisVPN exit node. Every knob comes from
# exit.env. Invoked by wg-hooks.sh from the wggvpn PostUp/PreDown hooks as
# `gvpn-peer-shaping.sh up|down`.
#
# Shapes (queues) instead of policing (dropping): each peer gets an HTB class
# with a guaranteed share and a per-peer ceil, plus an fq_codel leaf, so TCP
# settles smoothly at the cap instead of sawtoothing on hard packet loss. The
# parent class holds the node-wide aggregate cap for peer traffic; non-peer
# traffic has its own capped class beside it.
#
# Directions:
# - download (server -> peers): tree on wggvpn egress, classified by dst IP
# - upload (peers -> internet): wggvpn ingress mirrored to an ifb device, tree
#   on the ifb classified by src IP. Shaping must happen on the wggvpn side
#   because the public interface only sees post-MASQUERADE addresses.
#
# Peers are assigned GVPN_PEER_MIN_OCTET-GVPN_PEER_MAX_OCTET dynamically by
# gnosisvpn-server, so all classes in that range are provisioned up front and
# packets are steered by a u32 hash table on the last octet (O(1) per
# packet). .1 is the server itself and .255 the broadcast address; both land in
# the capped control class instead of a peer class. Range must stay within one
# /24 (this script only varies the last octet).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

WG_IF="wggvpn"
IFB_IF="ifb-gvpn"
SUBNET_PREFIX="${GVPN_PEER_SUBNET_PREFIX}"
# The aggregate, the per-peer ceil and the per-peer guarantee are derived in
# lib.sh from the measured uplink, the pool and the operator pins in exit.env:
# the aggregate is the budget for peer traffic, the ceil is what actually caps a
# peer, and the guarantee is that peer's share of it (the guarantees never add up
# to more than the aggregate).
PEER_RATE_KBIT="${GVPN_PEER_CEIL_KBIT}"
AGGREGATE_KBIT="${GVPN_PEER_SHAPING_AGGREGATE_KBIT}"
PEER_GUARANTEE_KBIT="${GVPN_PEER_GUARANTEE_KBIT}"
PEER_MIN="${GVPN_PEER_MIN_OCTET}"
PEER_MAX="${GVPN_PEER_MAX_OCTET}"
# Non-peer traffic (the server address, broadcasts) gets its own cap beside the
# peer budget, so it can never eat into the per-peer guarantees.
CONTROL_KBIT=1000
if (( AGGREGATE_KBIT < CONTROL_KBIT )); then
  CONTROL_KBIT="${AGGREGATE_KBIT}"
fi
# fq_codel tuned to signal congestion by queueing delay rather than drops: a
# dropped packet triggers an end-to-end retransmit across the mixnet, while a
# delayed packet lets the mixnet and TCP adapt to the slower pace. target
# tolerates ~250ms of standing queue (on top of the ~250ms mixnet peer RTT)
# before codel starts dropping, and ECN-capable flows are marked instead of
# dropped. Small quantum for inter-flow latency at low rates.
FQ_CODEL_OPTS="target 250ms interval 1000ms quantum 300 ecn"

# Refuse to build a tree from knobs lib.sh could not resolve (an invalid pin,
# or a pool too large for the aggregate to give every peer a 1 kbit/s share) and
# from rates that would over-subscribe the parent. Silently shaping to a
# different number, or overcommitting HTB, is worse than failing the interface.
require_shaping_config() {
  local count
  if ! kbit_ok "${AGGREGATE_KBIT}" || ! kbit_ok "${PEER_RATE_KBIT}" \
      || ! kbit_ok "${PEER_GUARANTEE_KBIT}"; then
    log "shaping is not configured: aggregate='${AGGREGATE_KBIT}' ceiling='${PEER_RATE_KBIT}' guarantee='${PEER_GUARANTEE_KBIT}' (check GVPN_PEER_RATE_KBIT, GVPN_PEER_SHAPING_AGGREGATE_KBIT, GVPN_PEER_MIN_SHARE_KBIT and the peer pool in exit.env)"
    return 1
  fi
  if ! peer_octet_range_ok "${PEER_MIN}" "${PEER_MAX}"; then
    log "peer pool ${PEER_MIN}..${PEER_MAX} must lie within 2..254"
    return 1
  fi
  if (( PEER_RATE_KBIT > AGGREGATE_KBIT || PEER_GUARANTEE_KBIT > PEER_RATE_KBIT )); then
    log "shaping rates are inconsistent: guarantee ${PEER_GUARANTEE_KBIT} <= ceiling ${PEER_RATE_KBIT} <= aggregate ${AGGREGATE_KBIT}"
    return 1
  fi
  count=$(( PEER_MAX - PEER_MIN + 1 ))
  if (( count * PEER_GUARANTEE_KBIT > AGGREGATE_KBIT )); then
    log "the ${count}-peer pool guarantees ${PEER_GUARANTEE_KBIT}kbit each, more than the ${AGGREGATE_KBIT}kbit aggregate"
    return 1
  fi
}

# Map a peer's last octet to the hex minor id of its class (1:<hex>).
peer_classid() {
  printf '%x' "${1}"
}

# IPv4 header offset of the address to classify on: dst for download (traffic
# leaving wggvpn toward peers), src for upload (peer traffic entering wggvpn,
# seen on the ifb mirror).
match_offset() {
  case "${1}" in
    dst) echo 16 ;;
    src) echo 12 ;;
    *) echo "unknown match direction: ${1}" >&2; return 1 ;;
  esac
}

# Print the full tc command batch for one device. ${2} is the match direction
# (dst|src). Consumed via `tc -batch -` so the whole tree is built in one
# netlink session instead of ~800 tc invocations.
emit_tree() {
  local dev="${1}" dir="${2}" offset octet minor
  offset="$(match_offset "${dir}")"

  echo "qdisc add dev ${dev} root handle 1: htb default fff"
  echo "class add dev ${dev} parent 1: classid 1:1 htb rate ${AGGREGATE_KBIT}kbit ceil ${AGGREGATE_KBIT}kbit"
  # non-peer traffic is a sibling of the peer budget, not a child of it
  echo "class add dev ${dev} parent 1: classid 1:fff htb rate ${CONTROL_KBIT}kbit ceil ${CONTROL_KBIT}kbit"
  echo "qdisc add dev ${dev} parent 1:fff fq_codel ${FQ_CODEL_OPTS}"
  echo "filter add dev ${dev} parent 1: prio 1 handle 2: protocol ip u32 divisor 256"
  echo "filter add dev ${dev} parent 1: prio 1 protocol ip u32 ht 800:: match ip ${dir} ${SUBNET_PREFIX}.0/24 hashkey mask 0x000000ff at ${offset} link 2:"

  for octet in $(seq "${PEER_MIN}" "${PEER_MAX}"); do
    minor="$(peer_classid "${octet}")"
    echo "class add dev ${dev} parent 1:1 classid 1:${minor} htb rate ${PEER_GUARANTEE_KBIT}kbit ceil ${PEER_RATE_KBIT}kbit"
    echo "qdisc add dev ${dev} parent 1:${minor} fq_codel ${FQ_CODEL_OPTS}"
    echo "filter add dev ${dev} parent 1: prio 1 protocol ip u32 ht 2:${minor}: match ip ${dir} ${SUBNET_PREFIX}.${octet}/32 flowid 1:${minor}"
  done
}

up() {
  # Before touching the interface, so a broken config leaves no half-built tree.
  require_shaping_config

  # download: replace whatever root qdisc is present (idempotent re-runs)
  tc qdisc del dev "${WG_IF}" root 2>/dev/null || true
  emit_tree "${WG_IF}" dst | tc -batch -

  # upload: mirror wggvpn ingress onto the ifb and shape there
  modprobe ifb numifbs=0 2>/dev/null || true
  ip link add "${IFB_IF}" type ifb 2>/dev/null || true
  ip link set "${IFB_IF}" up
  tc qdisc del dev "${IFB_IF}" root 2>/dev/null || true
  emit_tree "${IFB_IF}" src | tc -batch -
  tc qdisc del dev "${WG_IF}" ingress 2>/dev/null || true
  tc qdisc add dev "${WG_IF}" handle ffff: ingress
  tc filter add dev "${WG_IF}" parent ffff: prio 1 protocol ip u32 match u32 0 0 action mirred egress redirect dev "${IFB_IF}"
}

down() {
  tc qdisc del dev "${WG_IF}" ingress 2>/dev/null || true
  tc qdisc del dev "${WG_IF}" root 2>/dev/null || true
  ip link del "${IFB_IF}" 2>/dev/null || true
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
