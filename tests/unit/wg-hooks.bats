#!/usr/bin/env bats
# wg-hooks.sh installs the dynamic FORWARD/NAT rules, the MSS clamp, shaping
# and the blocklist guard when wggvpn comes up, guards before anything that
# forwards, and removes them again on the way down in reverse, never touching
# the static isolation jump.

load helpers

setup() {
  setup_sandbox
  mock_cmd iptables
  mock_cmd ipset
  export GVPN_SHAPING_BIN="${MOCK_BIN}/gvpn-peer-shaping.sh"
  mock_cmd gvpn-peer-shaping.sh
}

teardown() {
  teardown_sandbox
}

# The installing calls of `up`, i.e. without the idempotent pre-clean.
up_calls() {
  grep -v -e ' -D ' -e 'gvpn-peer-shaping.sh down' "${MOCK_LOG}"
}

@test "up installs the guards before anything that forwards" {
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  expected="ipset create gvpn-blocklist hash:net family inet maxelem 131072 -exist
iptables -I INPUT -i wggvpn -s 10.128.0.0/24 -d 10.128.0.1/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT
iptables -I FORWARD -i wggvpn -m set --match-set gvpn-blocklist dst -j DROP
iptables -I FORWARD -o wggvpn -m set --match-set gvpn-blocklist src -j DROP
iptables -I FORWARD -i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE
iptables -t mangle -A FORWARD -i wggvpn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
iptables -t mangle -A FORWARD -o wggvpn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
gvpn-peer-shaping.sh up
iptables -t nat -A POSTROUTING -s 10.128.0.0/24 -o lan0 -j MASQUERADE
iptables -A FORWARD -i wggvpn -o lan0 -j ACCEPT"
  diff <(echo "${expected}") <(up_calls)
}

# The client's tunnel-verification ping allowance is part of the tunnel's own
# ruleset, so it follows WIREGUARD_CIDR and WIREGUARD_ADDRESS.
@test "the tunnel verification ping follows the configured pool" {
  printf 'WIREGUARD_CIDR=10.9.0.0/24\nWIREGUARD_ADDRESS=10.9.0.1/32\n' > "${GVPN_EXIT_OVERRIDES}"
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  grep -qx 'iptables -I INPUT -i wggvpn -s 10.9.0.0/24 -d 10.9.0.1/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT' "${MOCK_LOG}"
}

@test "the MSS clamp follows a custom WIREGUARD_MTU" {
  printf 'WIREGUARD_MTU=1400\n' > "${GVPN_EXIT_OVERRIDES}"
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  [ "$(up_calls | grep -c 'TCPMSS --set-mss 1360')" -eq 2 ]
  ! up_calls | grep -q 'set-mss 1380'
}

@test "the private-range jump is inserted last so it lands first in FORWARD" {
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "$(up_calls | grep '^iptables -I FORWARD' | tail -1)" = "iptables -I FORWARD -i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE" ]
}

@test "up first removes leftovers so re-running never duplicates rules" {
  run "${LIBEXEC}/wg-hooks.sh" up
  first_install="$(grep -n -e ' -A ' -e ' -I ' "${MOCK_LOG}" | head -1 | cut -d: -f1)"
  pre="$(head -n "$((first_install - 1))" "${MOCK_LOG}")"
  [[ "${pre}" == *"iptables -D FORWARD -i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE"* ]]
  [[ "${pre}" == *"iptables -t nat -D POSTROUTING -s 10.128.0.0/24 -o lan0 -j MASQUERADE"* ]]
}

@test "up fails when a firewall rule cannot be installed" {
  mock_cmd iptables '[[ "$*" == *"-I FORWARD -i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE"* ]] && exit 1; exit 0'
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -ne 0 ]
}

@test "down removes what forwards first, then the guards, and tolerates missing rules" {
  mock_cmd iptables 'exit 1'
  mock_cmd gvpn-peer-shaping.sh 'exit 1'
  run "${LIBEXEC}/wg-hooks.sh" down
  [ "${status}" -eq 0 ]
  expected="iptables -D FORWARD -i wggvpn -o lan0 -j ACCEPT
iptables -t nat -D POSTROUTING -s 10.128.0.0/24 -o lan0 -j MASQUERADE
gvpn-peer-shaping.sh down
iptables -t mangle -D FORWARD -o wggvpn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
iptables -t mangle -D FORWARD -i wggvpn -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1380
iptables -D FORWARD -i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE
iptables -D FORWARD -o wggvpn -m set --match-set gvpn-blocklist src -j DROP
iptables -D FORWARD -i wggvpn -m set --match-set gvpn-blocklist dst -j DROP
iptables -D INPUT -i wggvpn -s 10.128.0.0/24 -d 10.128.0.1/32 -p icmp -m icmp --icmp-type 8 -j ACCEPT"
  diff <(echo "${expected}") <(calls)
}

@test "down leaves the ipset in place for the refresh timer" {
  run "${LIBEXEC}/wg-hooks.sh" down
  ! grep -q '^ipset destroy' "${MOCK_LOG}"
}

@test "usage error on an unknown action" {
  run "${LIBEXEC}/wg-hooks.sh" sideways
  [ "${status}" -eq 64 ]
}

# A stateful iptables mock: FORWARD lives in ${FORWARD_CHAIN}, one rule spec
# per line, seeded from the static ruleset. -I prepends, -A appends, -D
# removes the first exact match (exit 1 if none), like iptables does. After
# every change it records a violation if any rule accepting traffic from
# wggvpn is not preceded by a GVPN_PRIVATE jump. FAIL_ON makes the call whose
# arguments contain it fail without changing anything.
stateful_iptables() {
  export FORWARD_CHAIN="${SANDBOX}/forward.rules" VIOLATIONS="${SANDBOX}/violations.log"
  sed -n 's/^-A FORWARD //p' "${SHARE}/iptables.rules" > "${FORWARD_CHAIN}"
  : > "${VIOLATIONS}"
  mock_cmd iptables '
[[ -n "${FAIL_ON:-}" && "$*" == *"${FAIL_ON}"* ]] && exit 1
[[ "$1" == "-t" ]] && exit 0
op="$1" chain="$2"; shift 2
[[ "${chain}" == FORWARD ]] || exit 0
spec="$*"
case "${op}" in
  -I) { echo "${spec}"; cat "${FORWARD_CHAIN}"; } > "${FORWARD_CHAIN}.new" ;;
  -A) { cat "${FORWARD_CHAIN}"; echo "${spec}"; } > "${FORWARD_CHAIN}.new" ;;
  -D) awk -v s="${spec}" '\''!done && $0 == s {done = 1; next} {print} END {exit !done}'\'' \
        "${FORWARD_CHAIN}" > "${FORWARD_CHAIN}.new" || exit 1 ;;
esac
mv "${FORWARD_CHAIN}.new" "${FORWARD_CHAIN}"
awk -v call="iptables ${op} FORWARD ${spec}" '\''
  /-i wggvpn/ && /-j GVPN_PRIVATE$/ {isolated = 1}
  /-i wggvpn/ && /-j ACCEPT$/ && !isolated {print "after " call ": " $0}
'\'' "${FORWARD_CHAIN}" >> "${VIOLATIONS}"'
}

forward_chain() {
  cat "${FORWARD_CHAIN}"
}

STATIC_PRIVATE_JUMP='-i wggvpn -j GVPN_PRIVATE'

@test "up keeps the static isolation jump next to its own" {
  stateful_iptables
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  [ "$(forward_chain | grep -cxF -e "${STATIC_PRIVATE_JUMP}")" -eq 1 ]
  [ "$(forward_chain | grep -c -- '-i wggvpn .*-j GVPN_PRIVATE$')" -eq 2 ]
}

@test "no step of up, down or a restart lets wggvpn traffic past an ACCEPT unisolated" {
  stateful_iptables
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  run "${LIBEXEC}/wg-hooks.sh" down
  [ "${status}" -eq 0 ]
  diff /dev/null "${VIOLATIONS}"
}

@test "up from a clean slate ends with the guards, the static rules, then the uplink ACCEPT" {
  stateful_iptables
  run "${LIBEXEC}/wg-hooks.sh" up
  [ "${status}" -eq 0 ]
  expected="-i wggvpn -m comment --comment gvpn-wg-hooks -j GVPN_PRIVATE
-o wggvpn -m set --match-set gvpn-blocklist src -j DROP
-i wggvpn -m set --match-set gvpn-blocklist dst -j DROP
-i wggvpn -j GVPN_PRIVATE
-o wggvpn -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-i wggvpn -o lan0 -j ACCEPT"
  diff <(echo "${expected}") <(forward_chain)
}

@test "up then down restores exactly the static FORWARD chain" {
  stateful_iptables
  static="$(forward_chain)"
  run "${LIBEXEC}/wg-hooks.sh" up
  run "${LIBEXEC}/wg-hooks.sh" down
  [ "${status}" -eq 0 ]
  diff <(echo "${static}") <(forward_chain)
}

@test "a hook failing at any step never leaves wggvpn traffic unisolated" {
  for step in 'ipset' 'blocklist dst' 'blocklist src' 'GVPN_PRIVATE' 'shaping' 'MASQUERADE' '-o lan0 -j ACCEPT'; do
    stateful_iptables
    mock_cmd ipset "[[ '${step}' == ipset ]] && exit 1; exit 0"
    mock_cmd gvpn-peer-shaping.sh "[[ '${step}' == shaping && \$1 == up ]] && exit 1; exit 0"
    export FAIL_ON=""
    case "${step}" in
      'blocklist dst') FAIL_ON='-I FORWARD -i wggvpn -m set' ;;
      'blocklist src') FAIL_ON='-I FORWARD -o wggvpn -m set' ;;
      'GVPN_PRIVATE') FAIL_ON='-I FORWARD -i wggvpn -m comment' ;;
      'MASQUERADE') FAIL_ON='-A POSTROUTING' ;;
      '-o lan0 -j ACCEPT') FAIL_ON='FORWARD -i wggvpn -o lan0 -j ACCEPT' ;;
    esac
    run "${LIBEXEC}/wg-hooks.sh" up
    [ "${status}" -ne 0 ] || { echo "up succeeded although ${step} failed"; false; }
    diff /dev/null "${VIOLATIONS}" || { echo "while ${step} failed"; false; }
    forward_chain | grep -qxF -e "${STATIC_PRIVATE_JUMP}" || { echo "static jump lost while ${step} failed"; false; }
  done
}
