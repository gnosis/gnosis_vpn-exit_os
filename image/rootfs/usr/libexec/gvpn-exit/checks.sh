#!/usr/bin/env bash
# Functions behind the greenboot health checks and hooks. Sourced, never
# executed. Rule-order checks read `iptables -S <chain>` output on stdin.
#
# A reader that answers "ok" before the listing ends drains the rest of stdin
# before it returns. The callers pipe `iptables -S` into it under pipefail: a
# chain longer than one pipe buffer would otherwise kill the writer with
# SIGPIPE, and its 141 would replace the 0 the reader returned. The readers that
# answer "not ok" drain as well, though there it changes nothing: their own
# non-zero status is the one pipefail reports.

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

# Printed rules are matched by the fields that decide what they do, not by
# their exact text. `iptables -S` prints every match module a rule carries, so
# the same rule reads differently once it has a comment, an extra match or
# another netfilter backend behind it; an exact comparison would turn every
# provisioned boot red for a change that does not alter what the rule does. The
# two rules that carry the isolation itself are the exception: nothing may be
# added to them, so they are compared exactly, once their comments are off.
#
# rule_has LINE TOKEN...: every TOKEN appears as whole fields of LINE. A TOKEN
# may span adjacent fields ("-A INPUT").
rule_has() {
  local line=" $1 " token
  shift
  for token in "$@"; do
    [[ "${line}" == *" ${token} "* ]] || return 1
  done
}

# rule_has_none LINE TOKEN...: none of the TOKENs appears in LINE.
rule_has_none() {
  local line=" $1 " token
  shift
  for token in "$@"; do
    [[ "${line}" != *" ${token} "* ]] || return 1
  done
}

# A comment match as `iptables -S` prints it: `-m comment --comment "text"` with
# a quote inside escaped as \", or a single word without quotes.
COMMENT_RE='[[:space:]]-m[[:space:]]comment[[:space:]]--comment[[:space:]]("([^"\\]|\\.)*"|[^[:space:]]+)'

# without_comments LINE: the rule without its comment matches. iptables prints a
# comment's text verbatim, so a comment can read like rule syntax ("-i wggvpn
# -j DROP"); it selects nothing and must not be read as if it did.
without_comments() {
  local line=" $1 "
  while [[ "${line}" =~ ${COMMENT_RE} ]]; do
    line="${line/"${BASH_REMATCH[0]}"/}"
  done
  printf '%s\n' "${line# }"
}

# is_exactly LINE RULE: the printed rule is RULE, once its comments are taken
# off. iptables prints the fields in a fixed order and nothing else may be on the
# rule the callers below accept, so an exact comparison is what is left: an
# interface name with a space in it is installed with only a warning and printed
# back unquoted, which makes it read like a narrower rule than it is.
is_exactly() {
  local line
  line="$(without_comments "$1")"
  [[ "${line% }" == "$2" ]]
}

# interface_is LINE NAME: the rule matches on the interface NAME, not on a name
# that merely starts with it. iptables prints such a name unquoted, so what
# follows it in the line is a space rather than the next option.
interface_is() {
  local line=" $1 " rest
  [[ "${line}" == *" -i $2 "* ]] || return 1
  rest="${line#*" -i $2 "}"
  [[ "${rest}" == -* ]]
}

# single_option LINE OPTION: OPTION appears at most once. iptables prints an
# interface name with spaces as-is (`-i "x -i wggvpn"`), so a second -i in a
# printed line is a crafted name that reads like a second match, not a match.
single_option() {
  local line=" $1 "
  [[ "${line}" != *" $2 "*" $2 "* ]]
}

# match_module_other_than LINE MODULE...: the rule matches with a module that is
# not one of MODULE. A set name is printed unquoted, so `--match-set` with
# spaces in its name can otherwise pass for rule syntax.
match_module_other_than() {
  local line=" $1 " module want ok
  shift
  local -a allowed=("$@")
  while [[ "${line}" =~ -m[[:space:]]+([^[:space:]]+) ]]; do
    module="${BASH_REMATCH[1]}"
    ok=0
    for want in "${allowed[@]}"; do
      [[ "${module}" == "${want}" ]] && ok=1
    done
    (( ok )) || return 0
    line="${line#*"${BASH_REMATCH[0]}"}"
  done
  return 1
}

# rule_head LINE: the rule without its match modules and target. iptables prints
# the header fields first (-s, -d, -i, -o, -p, -f), then every -m module, then
# the target, so a set or comment name — printed unquoted or in quotes — cannot
# supply a header field of its own.
rule_head() {
  local line=" $1 "
  printf '%s\n' "${line%% -m *}"
}

# rule_verdict LINE: the target a printed rule hands the packet to (`-j` or
# `-g`). An empty answer means the line names no target, and the callers below
# treat that as a finding rather than as a rule they cannot decide about.
rule_verdict() {
  local line=" $1 "
  [[ "${line}" =~ .*[[:space:]](-j|-g)[[:space:]]+([^[:space:]]+) ]] || return 0
  printf '%s\n' "${BASH_REMATCH[2]}"
}

# single_target LINE: the rule prints exactly one target. A set name is printed
# unquoted, so `--match-set "s -j DROP"` reads like a target of its own and could
# hide the rule's real one behind it.
single_target() {
  local line=" $1 " token hits=0
  for token in -j -g; do
    while [[ "${line}" == *" ${token} "* ]]; do
      hits=$(( hits + 1 ))
      line="${line/ ${token} / }"
    done
  done
  (( hits == 1 ))
}

# rule_interface LINE: the interface a printed rule matches on, empty when it
# names none.
rule_interface() {
  local head
  head="$(rule_head "$1")"
  [[ "${head}" =~ [[:space:]]-i[[:space:]]+([^[:space:]]+) ]] || return 0
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# can_match_tunnel LINE: the rule can see traffic that arrives on the tunnel
# interface. A rule without -i matches every interface, `-i wggvpn` names the
# tunnel, and an interface with a `+` wildcard covers every name it starts with
# (`-i wg+` takes the tunnel too).
can_match_tunnel() {
  local iface
  iface="$(rule_interface "$1")"
  if [[ -z "${iface}" ]]; then
    return 0
  fi
  if [[ "${iface}" == *+ ]]; then
    [[ "wggvpn" == "${iface%+}"* ]]
    return
  fi
  [[ "${iface}" == wggvpn ]]
}

# is_established_accept LINE: an ACCEPT that matches only connections which
# already exist. It cannot open one: a client's connection to a private range is
# dropped as NEW ahead of the reply that would match this rule. The states are
# read from the conntrack match itself — the rule may carry no other module,
# which a set name could use to smuggle in a match of its own — and every state
# has to be ESTABLISHED or RELATED: a list that also names NEW opens connections.
is_established_accept() {
  local line match module
  line="$(without_comments "$1")"
  rule_has "${line}" "-j ACCEPT" || return 1
  [[ "${line}" =~ [[:space:]]-m[[:space:]]conntrack[[:space:]] ]] || return 1
  module="${BASH_REMATCH[0]}"
  match_module_other_than "${line}" conntrack && return 1
  match="${line#*"${module}"}"
  match="${match%% -m *}"
  [[ "${match}" =~ --ctstate[[:space:]]+([^[:space:]]+) ]] || return 1
  [[ "${BASH_REMATCH[1]}" =~ ^(ESTABLISHED|RELATED)(,(ESTABLISHED|RELATED))*$ ]]
}

# Targets that decide nothing: they log, mark or clamp the packet and return to
# the next rule, so a rule ahead of the isolation point that carries one cannot
# pass client traffic. Anything else that is not a verdict below — a jump to a
# chain whose contents this check cannot see, or a queue that hands the packet to
# a program outside the ruleset — is refused, because it may accept it.
NON_TERMINATING_TARGETS=" LOG NFLOG MARK CONNMARK TRACE AUDIT TCPMSS CLASSIFY SECMARK CONNSECMARK "

# ahead_is_safe LINE CHAIN
# A rule that sits ahead of the isolation point (the client drop in INPUT, the
# GVPN_PRIVATE jump in FORWARD) may not pass traffic from the tunnel. Either its
# target refuses the packet (DROP, REJECT, or RETURN into a DROP policy), or it
# decides nothing, or it cannot match tunnel traffic at all, or it is one of the
# allowances the device ships there. Everything else — an ACCEPT that can match
# tunnel traffic, a jump, a queue — is a way past the isolation, whatever the
# rule or its target is called.
#
# The established-connection ACCEPT is an allowance in INPUT only. The host
# never opens a connection to a client, so there is nothing on the tunnel for it
# to be established with. In FORWARD it would let a LAN host's own connection to
# a client carry the client's replies past the private-range jump.
ahead_is_safe() {
  local line verdict chain="$2"
  line="$(without_comments "$1")"
  # More than one target or a negated match in one printed line mean a crafted
  # interface or set name is being read as rule syntax; that is not a rule to
  # vouch for.
  single_target "${line}" || return 1
  rule_has_none "${line}" "!" || return 1
  verdict="$(rule_verdict "${line}")"
  case "${verdict}" in
    DROP|REJECT|RETURN) return 0 ;;
    ACCEPT) ;;
    *)
      if [[ "${NON_TERMINATING_TARGETS}" == *" ${verdict} "* ]]; then
        return 0
      fi
      return 1
      ;;
  esac
  if ! can_match_tunnel "${line}"; then
    return 0
  fi
  if [[ "${chain}" == INPUT ]] && is_established_accept "${line}"; then
    return 0
  fi
  is_vpn_ping "${line}"
}

# The static "nothing from wggvpn reaches the host" rule, and nothing else: a
# negated match (`! -i wggvpn`) selects the opposite traffic, a fragment match
# (`-f`) only the second and later fragments, and a narrowed one only part of it.
# iptables installs an interface name with spaces in it with nothing but a
# warning and prints it back unquoted, so such a name makes a rule read like a
# different one; the exact comparison refuses those.
is_client_drop() {
  is_exactly "$1" "-A INPUT -i wggvpn -j DROP"
}

# The unconditional jump that isolates VPN clients from private ranges, with or
# without the comment wg-hooks.sh tags its own copy with.
is_private_jump() {
  is_exactly "$1" "-A FORWARD -i wggvpn -j GVPN_PRIVATE"
}

# FORWARD policy is DROP and the wggvpn -> GVPN_PRIVATE jump precedes every rule
# that could pass client traffic, so VPN clients can never reach private ranges.
forward_isolation_ok() {
  local line seen_private=0 policy_drop=0
  while IFS= read -r line; do
    case "${line}" in
      "-P FORWARD DROP") policy_drop=1; continue ;;
      "-A FORWARD "*) ;;
      *) continue ;;
    esac
    if is_private_jump "${line}"; then
      seen_private=1
      continue
    fi
    if (( ! seen_private )); then
      if ! ahead_is_safe "${line}" FORWARD; then
        # Drain the rest of the listing; see the header.
        cat > /dev/null
        return 1
      fi
    fi
  done
  (( policy_drop && seen_private ))
}

# INPUT policy is DROP, traffic from VPN clients is dropped before any service
# port is accepted, and ahead of that drop only rules that cannot pass tunnel
# traffic may appear (see ahead_is_safe).
input_isolation_ok() {
  local line seen_drop=0 policy_drop=0
  while IFS= read -r line; do
    case "${line}" in
      "-P INPUT DROP") policy_drop=1; continue ;;
      "-A INPUT "*) ;;
      *) continue ;;
    esac
    if is_client_drop "${line}"; then
      seen_drop=1
      continue
    fi
    if (( ! seen_drop )); then
      if ! ahead_is_safe "${line}" INPUT; then
        # Drain the rest of the listing; see the header.
        cat > /dev/null
        return 1
      fi
    fi
  done
  (( policy_drop && seen_drop ))
}

# The GnosisVPN client pings the WireGuard server address through the tunnel
# (`connection.ping`, default 10.128.0.1) before it reports the connection
# established, so exactly that echo request must be accepted ahead of the
# client drop. wg-hooks.sh installs the rule from WIREGUARD_CIDR and
# WIREGUARD_ADDRESS, so the expectation is built from the same values and an
# edited exit.env cannot silently disagree with the live ruleset.
#
# The echo request is recognized by its fields: the tunnel interface, the
# client pool as source, the WireGuard address as destination, ICMP type 8 and
# ACCEPT. Everything else an operator adds (a comment, a rate-limit match)
# leaves it recognizable.
is_vpn_ping() {
  local address="${WIREGUARD_ADDRESS}" line
  # A bare address is a /32 once iptables has printed it.
  [[ "${address}" == */* ]] || address="${address}/32"
  line="$(without_comments "$1")"
  rule_has "${line}" "-A INPUT" "-j ACCEPT" "-p icmp" "-m icmp" "--icmp-type 8" \
    "-s ${WIREGUARD_CIDR}" "-d ${address}" \
    && rule_has_none "${line}" "!" "-f" \
    && single_option "${line}" "-i" && interface_is "${line}" wggvpn \
    && ! match_module_other_than "${line}" icmp limit
}

input_vpn_ping_ok() {
  local line seen_ping=0
  while IFS= read -r line; do
    if is_client_drop "${line}"; then
      # What the client's ping meets, unless the allowance precedes it. Drain
      # the rest of the listing first; see the header.
      cat > /dev/null
      (( seen_ping ))
      return
    fi
    if (( ! seen_ping )) && is_vpn_ping "${line}"; then
      seen_ping=1
    fi
  done
  return 1
}

# The static chain must drop destinations in the dynamically populated set of
# the exit's own public IPv4 addresses. Rule placement within GVPN_PRIVATE is
# immaterial because every matching rule drops.
self_ipset_rule_ok() {
  local line
  while IFS= read -r line; do
    if rule_has "${line}" "-A GVPN_PRIVATE" "-j DROP" \
        "-m set --match-set ${GVPN_SELF_IPSET_NAME} dst"; then
      # Drain the rest of the listing; see the header.
      cat > /dev/null
      return 0
    fi
  done
  return 1
}

ip6_policies_drop() {
  local rules
  rules="$(cat)"
  grep -qx -- '-P INPUT DROP' <<< "${rules}" \
    && grep -qx -- '-P FORWARD DROP' <<< "${rules}" \
    && grep -qx -- '-P OUTPUT DROP' <<< "${rules}"
}

# wait_units_active TIMEOUT_S UNIT...
# Poll until every unit is active; on timeout print the ones that are not.
wait_units_active() {
  local timeout="$1" deadline unit pending
  shift
  deadline=$(( SECONDS + timeout ))
  while :; do
    pending=()
    for unit in "$@"; do
      systemctl is-active --quiet "${unit}" || pending+=("${unit}")
    done
    (( ${#pending[@]} == 0 )) && return 0
    if (( SECONDS >= deadline )); then
      echo "not active after ${timeout}s: ${pending[*]}"
      return 1
    fi
    sleep 5
  done
}

# unit_stays_up UNIT SECONDS
# The unit is still active after SECONDS and systemd did not restart it
# meanwhile.
unit_stays_up() {
  local unit="$1" seconds="$2" before
  before="$(systemctl show -p NRestarts --value "${unit}")"
  sleep "${seconds}"
  systemctl is-active --quiet "${unit}" \
    && [[ "$(systemctl show -p NRestarts --value "${unit}")" == "${before}" ]]
}

# wait_for TIMEOUT_S COMMAND...
# Poll COMMAND until it succeeds, every GVPN_WAIT_INTERVAL_S (5) seconds, for at
# most TIMEOUT_S seconds. Checks use it for state that appears shortly after a
# Type=simple unit starts, so a slow start is not a red boot.
wait_for() {
  local timeout="$1" deadline interval="${GVPN_WAIT_INTERVAL_S:-5}"
  shift
  deadline=$(( SECONDS + timeout ))
  while :; do
    "$@" && return 0
    (( SECONDS < deadline )) || return 1
    sleep "${interval}"
  done
}

# Whether the v5 provisioning file exists. Until it does on a device updated
# from v4, hoprd.service stays stopped by its own condition; the migration
# helper writes the file and then starts it.
hoprd_v5_configured() {
  # Same predicate as hoprd.service's ConditionPathExists=: an empty file
  # counts as configured here, and the service then fails its own URL check.
  [[ -f "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env" ]]
}

# Blokli URL hoprd is provisioned with. An upgraded device may still carry
# only the v4 file until gvpn-exit-hoprd-migrate writes the v5 one.
provisioned_blokli_url() {
  local file
  file="$(hoprd_env_file)" || return 0
  sed -n 's/^HOPRD_BLOKLI_URL=//p' "${file}"
}

# blokli_answers URL
# Blokli answers a GraphQL query at URL/graphql. hoprd sends one at startup
# and exits when it fails, so this is what hoprd needs to come up.
blokli_answers() {
  curl -fsS --max-time 10 -o /dev/null -H 'Content-Type: application/json' \
    --data '{"query":"{__typename}"}' "${1%/}/graphql"
}

# snapshots_to_prune DIR KEEP_DIGEST...
# Print snapshot directories in DIR that belong to none of the given digests.
snapshots_to_prune() {
  local dir="$1" snapshot keep
  shift
  for snapshot in "${dir}"/*; do
    [[ -d "${snapshot}" ]] || continue
    for keep in "$@"; do
      [[ -n "${keep}" && "$(basename "${snapshot}")" == "${keep}" ]] && continue 2
    done
    echo "${snapshot}"
  done
}

# Append a digest to state/rejected-digests (once), keeping the last 10.
record_rejected_digest() {
  local digest="$1" file="${GVPN_STATE_DIR}/rejected-digests"
  mkdir -p "${GVPN_STATE_DIR}"
  touch "${file}"
  grep -qxF "${digest}" "${file}" && return 0
  { cat "${file}"; echo "${digest}"; } | tail -n 10 | write_atomic "${file}"
}
