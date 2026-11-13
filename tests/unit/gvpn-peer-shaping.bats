#!/usr/bin/env bats
# Unit tests for the tc command generation in gvpn-peer-shaping.sh.
# exit.env overrides supply the knob values. Each test sources the script in its
# own subshell (the dispatch is guarded by
# a BASH_SOURCE check) so `set -euo pipefail` from the script never leaks into
# the bats runner.

load helpers

setup() {
  setup_sandbox
  export GVPN_EXIT_OVERRIDES="${BATS_TEST_DIRNAME}/fixtures/exit-env-overrides.env"
  RENDERED="${LIBEXEC}/gvpn-peer-shaping.sh"
}

teardown() {
  teardown_sandbox
}

# Run a snippet against the sourced functions in a clean subshell.
in_script() {
  bash -c 'source "$1"; shift; "$@"' _ "${RENDERED}" "$@"
}

# Evaluate a snippet with the script sourced, so a test can replace the globals
# the derivation sets.
in_shaping() {
  bash -c 'source "$1"; shift; eval "$*"' _ "${RENDERED}" "$@"
}

@test "peer_classid maps the peer octet to a lowercase hex classid minor" {
  [ "$(in_script peer_classid 2)" = "2" ]
  [ "$(in_script peer_classid 165)" = "a5" ]
  [ "$(in_script peer_classid 254)" = "fe" ]
}

@test "match_offset selects the IP header offset for the match direction" {
  [ "$(in_script match_offset dst)" = "16" ]
  [ "$(in_script match_offset src)" = "12" ]
}

@test "match_offset rejects an unknown direction" {
  run in_script match_offset both
  [ "${status}" -ne 0 ]
}

@test "emit_tree creates an HTB root that defaults to the non-peer class" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q '^qdisc add dev wggvpn root handle 1: htb default fff$'
}

@test "emit_tree caps the aggregate at the configured rate" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q '^class add dev wggvpn parent 1: classid 1:1 htb rate 30000kbit ceil 30000kbit$'
}

@test "emit_tree creates one class per peer plus parent and default" {
  count="$(in_script emit_tree wggvpn dst | grep -c '^class add ')"
  [ "${count}" -eq 255 ]
}

@test "emit_tree caps every peer class at the per-peer rate" {
  count="$(in_script emit_tree wggvpn dst | grep -c 'ceil 7500kbit$')"
  [ "${count}" -eq 253 ]
}

@test "emit_tree configures fq_codel leaves for delay-based congestion signaling" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q 'fq_codel target 250ms interval 1000ms quantum 300 ecn$'
}

@test "emit_tree attaches an fq_codel leaf to every peer class and the default class" {
  count="$(in_script emit_tree wggvpn dst | grep -c '^qdisc add dev wggvpn parent 1:.* fq_codel ')"
  [ "${count}" -eq 254 ]
}

@test "emit_tree hashes downloads on the destination address" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q 'match ip dst 10.128.0.0/24 hashkey mask 0x000000ff at 16 link 2:'
}

@test "emit_tree hashes uploads on the source address" {
  result="$(in_script emit_tree ifb-gvpn src)"
  echo "${result}" | grep -q 'match ip src 10.128.0.0/24 hashkey mask 0x000000ff at 12 link 2:'
}

@test "emit_tree gives non-peer traffic its own cap beside the peer budget" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q '^class add dev wggvpn parent 1: classid 1:fff htb rate 1000kbit ceil 1000kbit$'
  ! echo "${result}" | grep -q 'parent 1:1 classid 1:fff'
}

@test "emit_tree never gives non-peer traffic more than the aggregate" {
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/etc/exit.env"
  printf 'GVPN_PEER_MAX_OCTET=2\nGVPN_PEER_SHAPING_AGGREGATE_KBIT=750\n' > "${GVPN_EXIT_OVERRIDES}"
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q '^class add dev wggvpn parent 1: classid 1:fff htb rate 750kbit ceil 750kbit$'
}

@test "emit_tree sizes one class per peer slot from the derived guarantee and ceiling" {
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/etc/exit.env"
  printf 'GVPN_PEER_MIN_OCTET=2\nGVPN_PEER_MAX_OCTET=11\nGVPN_PEER_RATE_KBIT=10000\nGVPN_PEER_SHAPING_AGGREGATE_KBIT=50000\n' \
    > "${GVPN_EXIT_OVERRIDES}"
  result="$(in_script emit_tree wggvpn dst)"
  [ "$(echo "${result}" | grep -c 'parent 1:1 classid 1:[0-9a-f]* htb rate 5000kbit ceil 10000kbit$')" -eq 10 ]
}

@test "emit_tree derives the pool from the aggregate when the pool is auto" {
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/etc/exit.env"
  printf 'GVPN_PEER_SHAPING_AGGREGATE_KBIT=50000\n' > "${GVPN_EXIT_OVERRIDES}"
  result="$(in_script emit_tree wggvpn dst)"
  # Ten slots at 5 Mbit/s each, .2 to .11.
  [ "$(echo "${result}" | grep -c 'parent 1:1 classid 1:[0-9a-f]* htb rate 5000kbit ceil 10000kbit$')" -eq 10 ]
  echo "${result}" | grep -q 'match ip dst 10.128.0.11/32 flowid 1:b$'
}

@test "up refuses an unresolved shaping config before touching the interface" {
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/etc/exit.env"
  printf 'GVPN_PEER_RATE_KBIT=0\nGVPN_PEER_MAX_OCTET=3\nGVPN_PEER_SHAPING_AGGREGATE_KBIT=25000\n' > "${GVPN_EXIT_OVERRIDES}"
  mock_cmd tc 'exit 0'
  mock_cmd ip 'exit 0'
  run in_script up
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"shaping is not configured"* ]]
  [ ! -s "${MOCK_LOG}" ]
}

# A measurement is not a pin: whatever the probe cached, shaping has a tree to
# build, so the required greenboot shaping check cannot go red over a sample.
@test "up builds the tree for a pinned pool whatever the probe measured" {
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/etc/exit.env"
  printf 'GVPN_PEER_MAX_OCTET=254\n' > "${GVPN_EXIT_OVERRIDES}"
  seed_capacity 1000 1000
  run in_script require_shaping_config
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  result="$(in_script emit_tree wggvpn dst)"
  [ "$(echo "${result}" | grep -c 'parent 1:1 classid 1:[0-9a-f]* htb rate 29kbit ceil 7500kbit$')" -eq 253 ]
}

@test "the shaping guard refuses guarantees that over-subscribe the aggregate" {
  # lib.sh never derives such a pool (it leaves the values unresolved), so this
  # asserts the invariant the guard exists for, not a reachable pin.
  run in_shaping 'AGGREGATE_KBIT=1000 PEER_RATE_KBIT=1000 PEER_GUARANTEE_KBIT=100 PEER_MIN=2 PEER_MAX=254; require_shaping_config'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"253-peer pool guarantees 100kbit each, more than the 1000kbit aggregate"* ]]
}

@test "the shaping guard refuses a ceiling above the aggregate" {
  run in_shaping 'AGGREGATE_KBIT=100 PEER_RATE_KBIT=1000 PEER_GUARANTEE_KBIT=100 PEER_MIN=2 PEER_MAX=3; require_shaping_config'
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"shaping rates are inconsistent"* ]]
}

@test "emit_tree covers the full dynamic peer range .2 through .254" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q 'match ip dst 10.128.0.2/32 flowid 1:2$'
  echo "${result}" | grep -q 'match ip dst 10.128.0.254/32 flowid 1:fe$'
}

@test "emit_tree never shapes the server or broadcast addresses" {
  result="$(in_script emit_tree wggvpn dst)"
  ! echo "${result}" | grep -q 'match ip dst 10.128.0.1/32'
  ! echo "${result}" | grep -q 'match ip dst 10.128.0.255/32'
}

@test "emit_tree places every peer filter in its own hash bucket" {
  result="$(in_script emit_tree wggvpn dst)"
  echo "${result}" | grep -q 'ht 2:a5: match ip dst 10.128.0.165/32 flowid 1:a5$'
}

@test "usage error on a missing or unknown action" {
  run bash "${RENDERED}"
  [ "${status}" -ne 0 ]
  run bash "${RENDERED}" sideways
  [ "${status}" -ne 0 ]
}
