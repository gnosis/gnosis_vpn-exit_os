#!/usr/bin/env bats
# The NetworkManager dispatcher binds sshd to lan0's current address and
# loopback. sshd reads the drop-in only when it carries the SELinux type of
# sshd's own configuration, so the script labels it before sshd reloads.

load helpers

DISPATCHER="${ROOTFS}/usr/lib/NetworkManager/dispatcher.d/50-gvpn-exit-sshd-listen"

setup() {
  setup_sandbox
  unset IP4_ADDRESS_0 DHCP4_IP_ADDRESS
  export GVPN_SSHD_LISTEN_CONF="${SANDBOX}/run/sshd_config.d/10-listen.conf"
  export GVPN_SSHD_LABEL_REFERENCE="${SANDBOX}/etc/sshd_config"
  touch "${GVPN_SSHD_LABEL_REFERENCE}"
  mock_cmd chcon
  mock_cmd systemctl
}

teardown() {
  teardown_sandbox
}

@test "up binds sshd to the lan0 address and loopback, labelled before the reload" {
  IP4_ADDRESS_0="192.168.1.20/24 192.168.1.1" run "${DISPATCHER}" lan0 up
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_SSHD_LISTEN_CONF}")" = "$(printf 'ListenAddress 192.168.1.20\nListenAddress 127.0.0.1')" ]
  [ "$(calls)" = "$(printf '%s\n' \
    "chcon --reference=${GVPN_SSHD_LABEL_REFERENCE} ${GVPN_SSHD_LISTEN_CONF}" \
    'systemctl try-reload-or-restart sshd.service')" ]
}

# NetworkManager passes a lease change with the DHCP4_* options, not
# necessarily with a current IP4_ADDRESS_0.
@test "a lease change binds sshd to the leased address" {
  DHCP4_IP_ADDRESS=10.0.0.7 IP4_ADDRESS_0="10.0.0.5/24 10.0.0.1" run "${DISPATCHER}" lan0 dhcp4-change
  [ "${status}" -eq 0 ]
  grep -qx 'ListenAddress 10.0.0.7' "${GVPN_SSHD_LISTEN_CONF}"
  ! grep -q '10.0.0.5' "${GVPN_SSHD_LISTEN_CONF}"
  grep -qx 'systemctl try-reload-or-restart sshd.service' "${MOCK_LOG}"
}

@test "an event without a usable address changes nothing" {
  run "${DISPATCHER}" lan0 dhcp4-change
  [ "${status}" -eq 0 ]
  DHCP4_IP_ADDRESS=$'10.0.0.7\nPermitRootLogin yes' run "${DISPATCHER}" lan0 dhcp4-change
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_SSHD_LISTEN_CONF}" ]
  [ ! -s "${MOCK_LOG}" ]
}

@test "down returns sshd to all addresses" {
  mkdir -p "$(dirname "${GVPN_SSHD_LISTEN_CONF}")"
  echo 'ListenAddress 192.168.1.20' > "${GVPN_SSHD_LISTEN_CONF}"
  run "${DISPATCHER}" lan0 down
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_SSHD_LISTEN_CONF}" ]
  grep -qx 'systemctl try-reload-or-restart sshd.service' "${MOCK_LOG}"
}

@test "other interfaces are ignored" {
  IP4_ADDRESS_0="10.0.0.5/24" run "${DISPATCHER}" wggvpn up
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_SSHD_LISTEN_CONF}" ]
  [ ! -s "${MOCK_LOG}" ]
}
