#!/usr/bin/env bash
# gvpn-exit-netprobe.service (every 15 min via its timer).
#
# Reports the network situation and refreshes the self-address firewall set.
# HOPRd address updates belong to gvpn-exit-hoprd-address; no port is mapped
# on the router.
#
# 1. Public IPv4 as seen from the internet (three independent HTTPS
#    services; the first valid answer wins, a disagreement is logged).
# 2. The router's own external address, read via UPnP-IGD with NAT-PMP as
#    fallback.
# 3. Classify the NAT situation (CGNAT / double NAT) from the public address
#    and the router's external address.
# 4. Record everything in state/reachability.json, which the heartbeat,
#    gvpn-exit-status and self-ipset.sh read.
#
# Offline runs record an unknown public address and exit 0.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

# shellcheck source=public-ip.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/public-ip.sh"
# natpmpc retries with exponential backoff (~2 min) when no gateway answers,
# so bound every router call.
GVPN_ROUTER_PROBE_TIMEOUT_S="${GVPN_ROUTER_PROBE_TIMEOUT_S:-10}"
REACHABILITY="${GVPN_STATE_DIR}/reachability.json"
SELF_IPSET_BIN="${GVPN_SELF_IPSET_BIN:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/self-ipset.sh}"
IPTABLES="${GVPN_IPTABLES_BIN:-iptables}"
IPTABLES_RESTORE="${GVPN_IPTABLES_RESTORE_BIN:-iptables-restore}"
# UDP source port of the router's answer to our SSDP query (UPnP-IGD
# discovery): the query goes to the multicast group 239.255.255.250:1900 and
# the router answers from its own address and port 1900, which is not the
# address the query went to, so conntrack cannot reverse it. NAT-PMP is a
# unicast exchange with the gateway's port 5351, so conntrack accepts that
# answer on its own and it needs no rule.
ROUTER_REPLY_PORTS=(1900)
SSDP_GATEWAY=""
ROUTER_EXTERNAL=""

lan_ip() {
  ip -4 -o addr show dev "${NETWORK_INTERFACE}" | awk '{split($4, a, "/"); print a[1]; exit}'
}

gateway_ipv4() {
  ip -4 route show default dev "${NETWORK_INTERFACE}" 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }'
}

# Open the router's reply path for the duration of one probe.
#
# The SSDP query goes to the router's multicast group, and the router answers
# from its own address to an ephemeral port; those answers are not covered by
# the static conntrack rule, because the answer does not come from the address
# the query was sent to. The answer is accepted only from the default gateway
# and only while the probe runs: a standing rule on the source port alone would
# let any LAN host reach every UDP service on the device, WireGuard on 51820
# included.
router_replies_open() {
  local gateway port
  # A device whose LAN interface is not up yet has no gateway: that is not a
  # probe failure, and `ip route` failing must not end the run.
  gateway="$(gateway_ipv4)" || gateway=""
  [[ -n "${gateway}" ]] || return 0
  # Replace, never stack: a probe killed without its traps (SIGKILL, a power
  # cut) leaves its rule behind, and the next probe must not add a second one. A
  # chain that cannot be read is no reason to add one anyway: every run would add
  # another and none of them would come out again.
  router_replies_close "${gateway}" || return 0
  SSDP_GATEWAY="${gateway}"
  for port in "${ROUTER_REPLY_PORTS[@]}"; do
    "${IPTABLES}" -I INPUT 1 -i "${NETWORK_INTERFACE}" -s "${SSDP_GATEWAY}" \
      -p udp -m udp --sport "${port}" -j ACCEPT 2>/dev/null || true
  done
}

# The reply-path rules currently in INPUT, one printed rule per line.
#
# The interface is read from the head of the rule only — iptables prints the
# header fields ahead of every match — and what follows the source port has to be
# nothing or a comment this script did not write, ending in the target. A set or
# comment name, which is printed unquoted or verbatim, therefore cannot pass for
# this rule's interface, port or target.
reply_rules() {
  "${IPTABLES}" -S INPUT 2>/dev/null | awk -v port="$1" -v iface="${NETWORK_INTERFACE}" '
    /^-A INPUT / {
      head = $0
      sub(/ -m .*/, "", head)
      sport = index($0, " --sport " port " ")
      if (index(head, " -i " iface " ") && sport) {
        tail = substr($0, sport + length(" --sport " port " "))
        if (tail == "-j ACCEPT" || tail ~ /^-m comment --comment ("([^"\\]|\\.)*"|[^ "]+) -j ACCEPT$/) print $0
      }
    }'
}

# Close the reply path: every rule of this shape goes, whatever gateway it names
# and whatever else it carries. Each specification comes from the chain itself
# and goes back as one restore batch, so iptables parses a comment's text the way
# it printed it, no rule number can go stale between reading the chain and
# deleting from it, and a rule that went away meanwhile cannot keep the others in
# place.
router_replies_close() {
  local gateway="${1:-${SSDP_GATEWAY}}" port rules rule
  [[ -n "${gateway}" ]] || return 0
  for port in "${ROUTER_REPLY_PORTS[@]}"; do
    if ! rules="$(reply_rules "${port}")"; then
      log "WARN could not read INPUT; the reply path is left as it is"
      return 1
    fi
    while IFS= read -r rule; do
      [[ -n "${rule}" ]] || continue
      printf '*filter\n-D INPUT %s\nCOMMIT\n' "${rule#-A INPUT }" \
        | "${IPTABLES_RESTORE}" --noflush 2>/dev/null \
        || log "WARN could not remove a router reply rule; the next probe sweeps it"
    done <<< "${rules}"
  done
  SSDP_GATEWAY=""
}

# The router's own external address: UPnP-IGD status, else NAT-PMP. It sets
# ROUTER_EXTERNAL instead of printing, so the open and the close of the reply
# path happen in this shell and a trap can reach them.
router_external_ip() {
  local external
  ROUTER_EXTERNAL=""
  router_replies_open
  external="$(timeout "${GVPN_ROUTER_PROBE_TIMEOUT_S}" upnpc -s 2>/dev/null | awk -F' = ' '/ExternalIPAddress/ {print $2; exit}')" || true
  if [[ -z "${external}" ]]; then
    external="$(timeout "${GVPN_ROUTER_PROBE_TIMEOUT_S}" natpmpc 2>/dev/null | awk -F ' : ' '/Public IP address/ {print $2; exit}')" || true
  fi
  # A sweep that cannot read the chain has already warned; the report is what
  # this run is for, and the EXIT trap tries the sweep again.
  router_replies_close || true
  # An unusable answer is "unknown", not a failure of the probe.
  if is_ipv4 "${external}"; then
    ROUTER_EXTERNAL="${external}"
  fi
}

# Classify the NAT in front of the device.
#   $1 public IPv4 seen by the internet
#   $2 router's own external IPv4 from UPnP/NAT-PMP (empty if unknown)
# Prints one of: ok | cgnat | double_nat | unknown
classify_nat() {
  local public="$1" router_external="$2"
  # Shared address space indicates CGNAT even when both observations match.
  # A mismatch alone cannot distinguish NAT from a proxy or multiple uplinks.
  if ipv4_in_cidr "${public}" 100.64.0.0/10 ||
      { [[ -n "${router_external}" ]] && ipv4_in_cidr "${router_external}" 100.64.0.0/10; }; then
    echo cgnat
  elif [[ -z "${router_external}" ]]; then
    echo unknown
  elif [[ "${router_external}" == "${public}" ]]; then
    echo ok
  elif ipv4_in_cidr "${router_external}" 10.0.0.0/8 ||
      ipv4_in_cidr "${router_external}" 172.16.0.0/12 ||
      ipv4_in_cidr "${router_external}" 192.168.0.0/16; then
    echo double_nat
  else
    echo unknown
  fi
}

write_reachability() {
  local public="$1" lan="$2" router_external="$3" nat="$4" previous='{}'
  if [[ -s "${REACHABILITY}" ]]; then
    previous="$(< "${REACHABILITY}")"
  fi
  jq -n \
    --argjson previous "${previous}" \
    --arg public "${public}" \
    --arg lan "${lan}" \
    --arg router_external "${router_external}" \
    --arg nat "${nat}" \
    --arg checked_at "$(date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ)" \
    '$previous + {
      public_ip: ($public | select(. != "") // null),
      lan_ip: ($lan | select(. != "") // null),
      router_external_ip: ($router_external | select(. != "") // null),
      nat: $nat,
      cgnat: ($nat == "cgnat"),
      checked_at: $checked_at
    }' | write_atomic "${REACHABILITY}"
}

main() {
  local public lan router_external nat lock_wait="${GVPN_NETPROBE_LOCK_WAIT_S:-300}"
  # One probe at a time. systemd never starts the unit twice, but an operator
  # running the script by hand would sweep the timer's rule and have its own
  # swept in turn. The wait is bounded so a run that cannot have the probe skips
  # this tick instead of holding a terminal for as long as the timer takes.
  [[ "${lock_wait}" =~ ^[0-9]+$ ]] || lock_wait=300
  mkdir -p "${GVPN_RUN_DIR}"
  exec 9>"${GVPN_RUN_DIR}/netprobe.lock"
  if ! flock -w "${lock_wait}" 9; then
    log "another probe holds ${GVPN_RUN_DIR}/netprobe.lock; skipping this run"
    return 0
  fi
  # A unit that is stopped mid-probe must not leave the gateway's reply path
  # open until the next firewall load.
  trap 'router_replies_close || true' EXIT
  trap 'router_replies_close || true; exit 1' INT TERM
  public="$(public_ip || true)"
  lan="$(lan_ip || true)"
  router_external_ip
  router_external="${ROUTER_EXTERNAL}"

  if [[ -n "${public}" ]]; then
    nat="$(classify_nat "${public}" "${router_external}")"
  else
    log "public IPv4 unknown (offline?)"
    nat="unknown"
  fi

  write_reachability "${public}" "${lan}" "${router_external}" "${nat}"
  if ! "${SELF_IPSET_BIN}"; then
    log "WARN failed to refresh self-address ipset"
  fi
  log "public=${public:-unknown} lan=${lan:-unknown} router_external=${router_external:-unknown} nat=${nat}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
