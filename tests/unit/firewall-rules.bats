#!/usr/bin/env bats
# Static rulesets: the isolation properties hold on the files as shipped,
# checked with the same functions the greenboot required check uses on the
# live ruleset.

load helpers

setup() {
  setup_sandbox
  RULES="${SHARE}/iptables.rules"
  RULES6="${SHARE}/ip6tables.rules"
}

teardown() {
  teardown_sandbox
}

# Render the -A/-P lines of CHAIN from an iptables-restore file the way
# `iptables -S CHAIN` prints them.
chain_s() {
  local file="$1" chain="$2"
  sed -n "s/^:${chain} \([A-Z]*\) .*/-P ${chain} \1/p" "${file}"
  grep "^-A ${chain} " "${file}" || true
}

@test "FORWARD sends wggvpn to GVPN_PRIVATE before any ACCEPT" {
  run bash -c 'source "$1"; forward_isolation_ok' _ "${LIBEXEC}/checks.sh" < <(chain_s "${RULES}" FORWARD)
  [ "${status}" -eq 0 ]
}

@test "INPUT drops wggvpn before any service port" {
  run bash -c 'source "$1"; input_isolation_ok' _ "${LIBEXEC}/checks.sh" < <(chain_s "${RULES}" INPUT)
  [ "${status}" -eq 0 ]
}

# The tunnel verification ping is installed with the tunnel and built from
# exit.env, so a changed pool cannot leave the client's ping behind the drop.
@test "the client's tunnel verification ping comes from the hooks, not the file" {
  run grep -E -- '-i wggvpn .*--icmp-type 8' "${RULES}"
  [ "${status}" -eq 1 ]
  grep -q 'PING_RULE=' "${LIBEXEC}/wg-hooks.sh"
  grep -q 'WIREGUARD_ADDRESS' "${LIBEXEC}/wg-hooks.sh"
}

@test "GVPN_PRIVATE covers RFC1918, CGNAT, link-local, loopback and multicast" {
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8 0.0.0.0/8 224.0.0.0/3; do
    grep -qx -- "-A GVPN_PRIVATE -d ${net} -j DROP" "${RULES}"
  done
}

@test "GVPN_PRIVATE drops the exit's own public addresses and the set exists before restore" {
  grep -qx -- '-A GVPN_PRIVATE -m set --match-set gvpn-self dst -j DROP' "${RULES}"
  run grep -n -E 'ExecStartPre=.*/self-ipset\.sh|ExecStart=.*/iptables-restore' \
    "${ROOTFS}/usr/lib/systemd/system/gvpn-exit-firewall.service"
  [ "${status}" -eq 0 ]
  [[ "${lines[0]}" == *'ExecStartPre='* ]]
  [[ "${lines[1]}" == *'iptables-restore'* ]]
}

@test "no unsolicited inbound accept for the hoprd p2p port" {
  run grep -- '--dport 9091 ' "${RULES}"
  [ "${status}" -eq 1 ]
}

@test "SSH is only accepted on lan0 from private sources" {
  run grep -- '--dport 22 ' "${RULES}"
  [ "${#lines[@]}" -eq 3 ]
  for line in "${lines[@]}"; do
    [[ "${line}" == "-A INPUT -i lan0 -s "* ]]
  done
}

# A source-port-only accept would hand every LAN host a path to every UDP
# service on the device, WireGuard included; netprobe.sh opens the router
# reply path to the gateway for its own duration instead.
@test "no standing accept for the router query source ports" {
  run grep -E -- '--sport (1900|5351) ' "${RULES}"
  [ "${status}" -eq 1 ]
  grep -q 'router_replies_open' "${LIBEXEC}/netprobe.sh"
}

@test "IPv6 policies are DROP on every chain" {
  run bash -c 'source "$1"; ip6_policies_drop' _ "${LIBEXEC}/checks.sh" < <(chain_s "${RULES6}" INPUT; chain_s "${RULES6}" FORWARD; chain_s "${RULES6}" OUTPUT)
  [ "${status}" -eq 0 ]
}

@test "the private-range chain the hooks jump to is declared in the static ruleset" {
  grep -qx ':GVPN_PRIVATE - \[0:0\]' "${RULES}"
  grep -q 'GVPN_PRIVATE' "${LIBEXEC}/wg-hooks.sh"
}
