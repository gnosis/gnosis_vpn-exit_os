#!/usr/bin/env bash
# Rebuild the gvpn-self ipset: this device's public IPv4 addresses from the
# saved hoprd address and the last netprobe report, which GVPN_PRIVATE drops
# for VPN clients. Runs before iptables-restore (which resolves the set name),
# after each netprobe run and after every address change. The live set is
# replaced with ipset swap so forwarding never observes an empty set.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env
# shellcheck source=public-ip.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/public-ip.sh"

IPSET_BIN="${GVPN_IPSET_BIN:-ipset}"
IPSET_NAME="${GVPN_SELF_IPSET_NAME}"
IPSET_MAXELEM="${GVPN_SELF_IPSET_MAXELEM:-16}"
# maxelem is a hard limit: ipset refuses a create above 4294967295, and an add
# fails once the set holds maxelem members. A set smaller than its members
# therefore breaks the populate, and the firewall unit, which resolves the set
# name, never loads.
# The three sources hold at most three members between them. The digits are
# bounded before the arithmetic: a longer number wraps in bash arithmetic and
# would pass the range check.
if ! [[ "${IPSET_MAXELEM}" =~ ^[1-9][0-9]{0,4}$ ]] || (( IPSET_MAXELEM < 3 || IPSET_MAXELEM > 65536 )); then
  log "WARN GVPN_SELF_IPSET_MAXELEM=${GVPN_SELF_IPSET_MAXELEM} is not an integer between 3 and 65536; using maxelem 16"
  IPSET_MAXELEM=16
fi
IPSET_STAGING="${IPSET_NAME}-staging-$$"
HOPRD_HOST_FILE="${GVPN_HOPRD_HOST_FILE:-${GVPN_STATE_DIR}/hoprd-host.env}"
REACHABILITY_FILE="${GVPN_REACHABILITY_FILE:-${GVPN_STATE_DIR}/reachability.json}"

add_public_member() {
  local candidate="$1" member
  # The three sources hold at most three members, and a hand-written report can
  # hold more: jq -r prints a value with embedded newlines as several lines.
  # Stop at three so the set is never asked for more than its smallest size.
  (( ${#MEMBERS[@]} < 3 )) || return 0
  member="${candidate%%:*}"
  is_public_ipv4 "${member}" || return 0
  [[ " ${MEMBERS[*]} " == *" ${member} "* ]] || MEMBERS+=("${member}")
}

collect_members() {
  local hoprd_host reachability
  if [[ -s "${HOPRD_HOST_FILE}" ]]; then
    hoprd_host="$(awk -F= '$1 == "HOPRD_HOST" { print $2; exit }' "${HOPRD_HOST_FILE}")" || hoprd_host=""
    add_public_member "${hoprd_host}"
  fi
  if [[ -s "${REACHABILITY_FILE}" ]]; then
    if reachability="$(jq -r '.public_ip // empty, .router_external_ip // empty' "${REACHABILITY_FILE}" 2>/dev/null)"; then
      while IFS= read -r member; do
        if [[ -n "${member}" ]]; then
          add_public_member "${member}"
        fi
      done <<< "${reachability}"
    else
      log "reachability state is unparsable; ignoring it"
    fi
  fi
}

main() {
  local member
  MEMBERS=()
  # Creating the set is what iptables-restore resolves at the next firewall
  # load, so a state file that cannot be read costs the members it held, never
  # the set: collect_members handles every read failure itself and returns 0.
  collect_members
  "${IPSET_BIN}" create "${IPSET_NAME}" hash:net family inet maxelem "${IPSET_MAXELEM}" -exist
  # A leftover staging set from an interrupted run of the same PID must not
  # abort the populate.
  "${IPSET_BIN}" destroy "${IPSET_STAGING}" 2>/dev/null || true
  "${IPSET_BIN}" create "${IPSET_STAGING}" hash:net family inet maxelem "${IPSET_MAXELEM}"
  for member in "${MEMBERS[@]}"; do
    "${IPSET_BIN}" add "${IPSET_STAGING}" "${member}"
  done
  "${IPSET_BIN}" swap "${IPSET_STAGING}" "${IPSET_NAME}"
  "${IPSET_BIN}" destroy "${IPSET_STAGING}"
  if (( ${#MEMBERS[@]} == 0 )); then
    log "no usable public IPv4 observations; self ipset is empty"
  else
    log "refreshed self ipset: ${MEMBERS[*]}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
