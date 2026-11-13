#!/usr/bin/env bats
# loopback-alias.sh keeps the session target the GnosisVPN client dials by
# default (172.30.0.1) on the loopback interface, so hoprd reaches the server
# there without a LAN route.

load helpers

SCRIPT="${LIBEXEC}/loopback-alias.sh"

setup() {
  setup_sandbox
  mock_cmd ip
}

teardown() {
  teardown_sandbox
}

@test "up assigns the session target address to lo" {
  run "${SCRIPT}" up
  [ "${status}" -eq 0 ]
  grep -qx 'ip addr replace 172.30.0.1/32 dev lo' "${MOCK_LOG}"
}

@test "down removes the session target address" {
  run "${SCRIPT}" down
  [ "${status}" -eq 0 ]
  grep -qx 'ip addr del 172.30.0.1/32 dev lo' "${MOCK_LOG}"
}

@test "the address and interface are overridable" {
  printf 'GVPN_SESSION_TARGET_ADDRESS=10.99.0.1/32\nGVPN_LOOPBACK_IFACE=lo0\n' > "${GVPN_EXIT_OVERRIDES}"
  run "${SCRIPT}" up
  [ "${status}" -eq 0 ]
  grep -qx 'ip addr replace 10.99.0.1/32 dev lo0' "${MOCK_LOG}"
}

@test "an unknown action is a usage error" {
  run "${SCRIPT}" sideways
  [ "${status}" -eq 64 ]
}
