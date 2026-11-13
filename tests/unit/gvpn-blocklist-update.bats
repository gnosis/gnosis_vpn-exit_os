#!/usr/bin/env bats
# Unit tests for the security-sensitive parsing/validation logic in
# gvpn-blocklist-update.sh. exit.env overrides supply the knob values. Each test
# sources the script in its own subshell (the dispatch is guarded by a
# BASH_SOURCE check) so
# `set -euo pipefail` from the script never leaks into the bats runner.

load helpers

setup() {
  setup_sandbox
  export GVPN_EXIT_OVERRIDES="${BATS_TEST_DIRNAME}/fixtures/exit-env-overrides.env"
  RENDERED="${LIBEXEC}/gvpn-blocklist-update.sh"
}

teardown() {
  teardown_sandbox
}

# Run a snippet against the sourced functions in a clean subshell.
in_script() {
  bash -c 'source "$1"; shift; "$@"' _ "${RENDERED}" "$@"
}

@test "parse_feed keeps a bare IPv4 address" {
  result="$(printf '%s\n' '50.16.16.211' | in_script parse_feed)"
  [ "${result}" = "50.16.16.211" ]
}

@test "parse_feed keeps a valid CIDR" {
  result="$(printf '%s\n' '10.0.0.0/8' | in_script parse_feed)"
  [ "${result}" = "10.0.0.0/8" ]
}

@test "parse_feed strips ; and # comments and surrounding whitespace" {
  input=$'; comment line\n  1.2.3.4  ; trailing comment\n10.0.0.0/8 # hash comment\n'
  result="$(printf '%s' "${input}" | in_script parse_feed)"
  [ "${result}" = $'1.2.3.4\n10.0.0.0/8' ]
}

@test "parse_feed drops octets greater than 255" {
  result="$(printf '%s\n' '999.1.1.1' '256.1.1.1' | in_script parse_feed)"
  [ -z "${result}" ]
}

@test "parse_feed drops prefixes greater than /32" {
  result="$(printf '%s\n' '10.0.0.0/33' '10.0.0.0/99' | in_script parse_feed)"
  [ -z "${result}" ]
}

@test "parse_feed rejects non-bogon prefixes shorter than /8" {
  input=$'0.0.0.0/0\n0.0.0.0/1\n128.0.0.0/1\n10.0.0.0/4\n192.168.0.0/7'
  result="$(printf '%s' "${input}" | in_script parse_feed)"
  [ -z "${result}" ]
}

@test "parse_feed keeps bogon prefixes shorter than /8 and ordinary IPv4 entries" {
  input=$'224.0.0.0/3\n240.0.0.0/4\n248.0.0.0/5\n0.0.0.0/8\n10.0.0.0/8\n203.0.113.0/24\n203.0.113.7'
  result="$(printf '%s' "${input}" | in_script parse_feed)"
  [ "${result}" = "${input}" ]
}

@test "parse_feed drops IPv6 and other non-IPv4 tokens" {
  result="$(printf '%s\n' '2001:db8::1' 'not-an-ip' '1.2.3' | in_script parse_feed)"
  [ -z "${result}" ]
}

@test "count_within_bounds rejects below MIN_ENTRIES (1000)" {
  run in_script count_within_bounds 999
  [ "${status}" -ne 0 ]
}

@test "count_within_bounds accepts exactly MIN_ENTRIES" {
  run in_script count_within_bounds 1000
  [ "${status}" -eq 0 ]
}

@test "count_within_bounds accepts a typical feed size" {
  run in_script count_within_bounds 3850
  [ "${status}" -eq 0 ]
}

@test "count_within_bounds accepts exactly IPSET_MAXELEM" {
  run in_script count_within_bounds 131072
  [ "${status}" -eq 0 ]
}

@test "count_within_bounds rejects above IPSET_MAXELEM" {
  run in_script count_within_bounds 131073
  [ "${status}" -ne 0 ]
}

@test "count_within_bounds rejects zero (empty set)" {
  run in_script count_within_bounds 0
  [ "${status}" -ne 0 ]
}

# The entry count alone lets a poisoned feed through: a few thousand /8s are
# thousands of entries and would drop most of the address space.
@test "coverage_within_bounds accepts an ordinary threat feed" {
  local list="${SANDBOX}/list.cidr" i
  for i in $(seq 1 2000); do echo "203.$((i / 256)).$((i % 256)).0/24"; done > "${list}"
  run in_script coverage_within_bounds "${list}"
  [ "${status}" -eq 0 ]
}

@test "coverage_within_bounds rejects a list that would drop most of IPv4" {
  local list="${SANDBOX}/poison.cidr" i
  : > "${list}"
  for i in $(seq 1 250); do echo "${i}.0.0.0/8"; done >> "${list}"
  run in_script coverage_within_bounds "${list}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"more than 25% of IPv4"* ]]
}

@test "coverage_within_bounds counts bare addresses as /32 and follows the knob" {
  local list="${SANDBOX}/list.cidr"
  printf '%s\n' 1.2.3.4 5.6.7.0/24 > "${list}"
  [ "$(in_script covered_addresses "${list}")" = "257" ]

  cp "${GVPN_EXIT_OVERRIDES}" "${SANDBOX}/overrides.env"
  echo "GVPN_BLOCKLIST_MAX_COVERAGE_PCT=1" >> "${SANDBOX}/overrides.env"
  GVPN_EXIT_OVERRIDES="${SANDBOX}/overrides.env" run in_script coverage_within_bounds "${list}"
  [ "${status}" -eq 0 ]

  # 1% of IPv4 is about 43M addresses; three /8s are 50M.
  printf '%s\n' 10.0.0.0/8 11.0.0.0/8 12.0.0.0/8 > "${list}"
  GVPN_EXIT_OVERRIDES="${SANDBOX}/overrides.env" run in_script coverage_within_bounds "${list}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"more than 1% of IPv4"* ]]
}

# The knob values of a whole run: the fixture the function tests use, plus
# directories inside the sandbox so no test touches the device paths.
run_overrides() {
  export GVPN_EXIT_OVERRIDES="${SANDBOX}/overrides.env"
  cp "${BATS_TEST_DIRNAME}/fixtures/exit-env-overrides.env" "${GVPN_EXIT_OVERRIDES}"
  printf 'GVPN_BLOCKLIST_CACHE_DIR=%s\nGVPN_BLOCKLIST_TEXTFILE_DIR=%s\n' \
    "${SANDBOX}/cache" "${SANDBOX}/textfile" >> "${GVPN_EXIT_OVERRIDES}"
}

# A feed URL is https, but a redirect is not bound by that: without the proto
# pins a mirror could send the fetch to plain http, where anyone on the path
# chooses the blocklist.
@test "the feed fetch never leaves https, not even on a redirect" {
  run_overrides
  mock_cmd curl 'exit 22'
  mock_cmd ipset

  run bash "${RENDERED}" --refresh

  [ "${status}" -eq 0 ]
  grep -q -- '--proto =https --proto-redir =https' "${MOCK_LOG}"
}

# gvpn-blocklist-boot.service is a required greenboot check, so a metrics write
# that fails has to leave the boot green: the set is what the boot needs.
@test "a metrics directory that cannot be written does not fail the boot load" {
  run_overrides
  printf 'GVPN_BLOCKLIST_TEXTFILE_DIR=%s\n' "${SANDBOX}/blocker/textfile" >> "${GVPN_EXIT_OVERRIDES}"
  : > "${SANDBOX}/blocker"
  mock_cmd ipset 'case "$1" in list) echo "Number of entries: 2000" ;; esac'

  run bash "${RENDERED}" --from-cache

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"cannot write"* ]]
}

# write_metrics calls the writer in a condition, where errexit is off, so the
# steps are chained: a write that stops part-way must not publish a truncated
# file over the previous one.
@test "a metrics write that stops part-way leaves the previous file in place" {
  run_overrides
  mkdir -p "${SANDBOX}/textfile"
  printf 'previous\n' > "${SANDBOX}/textfile/gvpn-blocklist.prom"
  # A filesystem that fills up: the temporary file is created and the write
  # stops after a few bytes.
  mock_cmd cat 'head -c 10; exit 1'
  mock_cmd ipset 'case "$1" in list) echo "Number of entries: 2000" ;; esac'

  run bash "${RENDERED}" --from-cache

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"cannot write"* ]]
  [ "$(< "${SANDBOX}/textfile/gvpn-blocklist.prom")" = "previous" ]
  [ ! -e "${SANDBOX}/textfile/gvpn-blocklist.prom.tmp" ]
}
