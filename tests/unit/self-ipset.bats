#!/usr/bin/env bats
# self-ipset.sh keeps the current public addresses out of VPN forwarding.

load helpers

setup() {
  setup_sandbox
  SCRIPT="${LIBEXEC}/self-ipset.sh"
  mock_cmd ipset
}

teardown() {
  teardown_sandbox
}

@test "creates the live set and atomically populates public addresses from every source" {
  printf 'HOPRD_HOST=8.8.8.8:9091\n' > "${GVPN_STATE_DIR}/hoprd-host.env"
  printf '{"public_ip":"1.1.1.1","router_external_ip":"9.9.9.9"}\n' > "${GVPN_STATE_DIR}/reachability.json"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  # A leftover staging set from an earlier run with the same PID is discarded
  # before the fresh one is created.
  [ "$(grep -n 'ipset destroy gvpn-self-staging-' "${MOCK_LOG}" | head -1 | cut -d: -f1)" \
    -lt "$(grep -n 'ipset create gvpn-self-staging-' "${MOCK_LOG}" | head -1 | cut -d: -f1)" ]
  grep -E -qx 'ipset add gvpn-self-staging-[0-9]+ 8\.8\.8\.8' "${MOCK_LOG}"
  grep -E -qx 'ipset add gvpn-self-staging-[0-9]+ 1\.1\.1\.1' "${MOCK_LOG}"
  grep -E -qx 'ipset add gvpn-self-staging-[0-9]+ 9\.9\.9\.9' "${MOCK_LOG}"
  grep -E -qx 'ipset swap gvpn-self-staging-[0-9]+ gvpn-self' "${MOCK_LOG}"
}

@test "drops private, CGNAT, special-use and duplicate observations" {
  printf 'HOPRD_HOST=8.8.8.8:9091\n' > "${GVPN_STATE_DIR}/hoprd-host.env"
  printf '{"public_ip":"8.8.8.8","router_external_ip":"100.64.0.1"}\n' > "${GVPN_STATE_DIR}/reachability.json"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "$(grep -c 'ipset add .* 8.8.8.8' "${MOCK_LOG}")" -eq 1 ]
  run grep -E ' (10\.0\.0\.1|100\.64\.0\.1|192\.0\.2\.1|198\.51\.100\.1)$' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "missing state files atomically leave an empty live set" {
  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  grep -E -qx 'ipset swap gvpn-self-staging-[0-9]+ gvpn-self' "${MOCK_LOG}"
  run grep 'ipset add ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The report an offline netprobe writes carries no address at all. The set still
# has to be created: iptables-restore resolves it on the next firewall load, and
# the firewall is ExecStartPre of everything that listens.
@test "a report with no address leaves the live set empty" {
  printf '{"public_ip":null,"router_external_ip":null}\n' > "${GVPN_STATE_DIR}/reachability.json"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  grep -E -qx 'ipset swap gvpn-self-staging-[0-9]+ gvpn-self' "${MOCK_LOG}"
  run grep 'ipset add ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "an empty report object leaves the live set empty" {
  printf '{}\n' > "${GVPN_STATE_DIR}/reachability.json"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  grep -E -qx 'ipset swap gvpn-self-staging-[0-9]+ gvpn-self' "${MOCK_LOG}"
  run grep 'ipset add ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# Collecting the members is best effort: whatever the state files hold, the set
# has to exist afterwards. The awk guard keeps a host file the tool cannot read
# out of the run, and an unparsable report is ignored rather than fatal.
@test "a saved address that cannot be read still creates the set" {
  printf 'HOPRD_HOST=8.8.8.8:9091\n' > "${GVPN_STATE_DIR}/hoprd-host.env"
  printf 'not json\n' > "${GVPN_STATE_DIR}/reachability.json"
  mock_cmd awk 'exit 2'

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  grep -E -qx 'ipset swap gvpn-self-staging-[0-9]+ gvpn-self' "${MOCK_LOG}"
  [[ "${output}" == *"unparsable"* ]]
  [[ "${output}" == *"self ipset is empty"* ]]
  run grep 'ipset add ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The static ruleset and the greenboot firewall check name the set, so a device
# override cannot rename it; the rest of the file still applies.
@test "a renamed self set in the device overrides is ignored" {
  printf 'GVPN_SELF_IPSET_NAME=gvpn-mine\n' > "${GVPN_EXIT_OVERRIDES}"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  run grep 'gvpn-mine' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "an unusable maxelem falls back to the default size" {
  local value
  for value in 0 1 2 -4 sixteen 99999999999 18446744073709551632; do
    printf 'GVPN_SELF_IPSET_MAXELEM=%s\n' "${value}" > "${GVPN_EXIT_OVERRIDES}"
    : > "${MOCK_LOG}"

    run "${SCRIPT}"

    [ "${status}" -eq 0 ]
    grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
    [[ "${output}" == *"not an integer between 3 and 65536"* ]]
  done
}

# The size has to hold the members as well as be one ipset accepts, so a value
# outside 3..65536 is replaced instead of reaching the create.
@test "a maxelem that is accepted is passed to both creates" {
  printf 'GVPN_SELF_IPSET_MAXELEM=3\n' > "${GVPN_EXIT_OVERRIDES}"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 3 -exist' "${MOCK_LOG}"
  grep -E -qx 'ipset create gvpn-self-staging-[0-9]+ hash:net family inet maxelem 3' "${MOCK_LOG}"
}

# A hand-written report can carry more addresses than the set holds: jq -r
# prints a value with embedded newlines as several lines. The three sources
# hold at most three members, so only the first three lines are collected.
@test "a report with more addresses than the set holds yields three members" {
  local addresses="" i
  printf 'HOPRD_HOST=8.8.8.8:9091\n' > "${GVPN_STATE_DIR}/hoprd-host.env"
  # One string value with escaped newlines, which jq -r prints as lines.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    addresses="${addresses}1.0.0.${i}\\n"
  done
  printf '{"public_ip":"%s","router_external_ip":"9.9.9.9"}\n' "${addresses}" \
    > "${GVPN_STATE_DIR}/reachability.json"

  run "${SCRIPT}"

  [ "${status}" -eq 0 ]
  [ "$(grep -c '^ipset add ' "${MOCK_LOG}")" -eq 3 ]
  grep -E -qx 'ipset add gvpn-self-staging-[0-9]+ 8\.8\.8\.8' "${MOCK_LOG}"
}

@test "fails when an ipset operation fails" {
  mock_cmd ipset '[[ "$1" != swap ]]'

  run "${SCRIPT}"

  [ "${status}" -ne 0 ]
}
