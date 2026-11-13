#!/usr/bin/env bats
# support-tunnel.sh: the one autossh command behind enroll-tunnel.service
# (enrollment key, unprovisioned) and support-tunnel.service (sealed support
# key, inside a support window).

load helpers

setup() {
  setup_sandbox
  export SUPPORT_PORT=22001
  export BASTION=support@bastion.example
  export GVPN_BASTION_KNOWN_HOSTS="${SANDBOX}/etc/bastion_known_hosts"
  echo "bastion.example ssh-ed25519 AAAA" > "${GVPN_BASTION_KNOWN_HOSTS}"
  mock_cmd autossh
}

teardown() {
  teardown_sandbox
}

@test "opens the reverse port on the bastion's loopback to the local sshd with the given key" {
  run "${LIBEXEC}/support-tunnel.sh" /etc/gvpn-exit/enroll.key
  [ "${status}" -eq 0 ]
  grep -q '^autossh -M 0 -N ' "${MOCK_LOG}"
  grep -q -- '-i /etc/gvpn-exit/enroll.key ' "${MOCK_LOG}"
  grep -q -- '-R 22001:127.0.0.1:22 support@bastion.example$' "${MOCK_LOG}"
}

@test "only talks to the pinned bastion host key" {
  run "${LIBEXEC}/support-tunnel.sh" /run/credentials/support-tunnel.service/support.key
  grep -q -- "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${GVPN_BASTION_KNOWN_HOSTS} " "${MOCK_LOG}"
  grep -q -- '-o IdentitiesOnly=yes ' "${MOCK_LOG}"
  grep -q -- '-o ExitOnForwardFailure=yes ' "${MOCK_LOG}"
}

@test "fails without a bastion or a port and never starts autossh" {
  unset BASTION
  run "${LIBEXEC}/support-tunnel.sh" /etc/gvpn-exit/enroll.key
  [ "${status}" -ne 0 ]
  export BASTION=support@bastion.example
  unset SUPPORT_PORT
  run "${LIBEXEC}/support-tunnel.sh" /etc/gvpn-exit/enroll.key
  [ "${status}" -ne 0 ]
  [ ! -s "${MOCK_LOG}" ]
}

@test "usage error without a key file" {
  run "${LIBEXEC}/support-tunnel.sh"
  [ "${status}" -ne 0 ]
  [ ! -s "${MOCK_LOG}" ]
}
