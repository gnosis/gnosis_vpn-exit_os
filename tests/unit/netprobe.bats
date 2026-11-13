#!/usr/bin/env bats
# netprobe.sh (every 15 min): public IPv4, the router's external address
# (read-only), CGNAT classification and state/reachability.json. This reporter
# never maps router ports or changes HOPRd's announcement settings.

load helpers

setup() {
  setup_sandbox
  export GVPN_NOW=1790220600
  printf 'GVPN_PUBLIC_IP_URLS="https://ip-a.example https://ip-b.example"\n' > "${GVPN_EXIT_OVERRIDES}"
  mock_cmd ip '
case "$*" in
  *"route show default"*) echo "default via 192.168.1.1 dev lan0 proto dhcp" ;;
  *) echo "2: lan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic lan0" ;;
esac'
  public_ip 203.0.113.7
  upnp_router 203.0.113.7
  mock_cmd natpmpc 'exit 1'
  mock_iptables
  mock_cmd systemctl
  export GVPN_SELF_IPSET_BIN="${MOCK_BIN}/self-ipset"
  mock_cmd self-ipset
}

# A stateful iptables: -I puts the rule at the head of the chain, -S prints the
# chain in order, and iptables-restore --noflush applies a -D batch the way the
# real one does — by specification, removing one instance per line and failing
# the batch when a line names a rule that is not there.
mock_iptables() {
  mock_cmd iptables '
rules="${SANDBOX}/iptables.state"
touch "${rules}"
key="${*}"
key="${key/-I INPUT 1 /}"
case "${1:-}" in
  -I) { echo "${key}"; cat "${rules}"; } > "${rules}.new"; mv "${rules}.new" "${rules}" ;;
  -S)
    if [[ "${2:-}" == INPUT ]]; then
      while IFS= read -r line; do echo "-A INPUT ${line}"; done < "${rules}"
    fi
    ;;
esac'
  mock_cmd iptables-restore '
rules="${SANDBOX}/iptables.state"
: > "${SANDBOX}/restore.batch"
while IFS= read -r line; do
  case "${line}" in
    -D\ INPUT\ *) echo "${line#-D INPUT }" >> "${SANDBOX}/restore.batch" ;;
  esac
done
# All or nothing: a line that names a rule which is not there applies none.
while IFS= read -r spec; do
  grep -qxF -- "${spec}" "${rules}" || exit 1
done < "${SANDBOX}/restore.batch"
while IFS= read -r spec; do
  gone=0
  kept=""
  while IFS= read -r held; do
    if (( ! gone )) && [[ "${held}" == "${spec}" ]]; then gone=1; continue; fi
    kept+="${held}"$'"'"'\n'"'"'
  done < "${rules}"
  printf "%s" "${kept}" > "${rules}"
done < "${SANDBOX}/restore.batch"'
}

# The rules the mock iptables still holds.
rules_installed() {
  cat "${SANDBOX}/iptables.state"
}

teardown() {
  teardown_sandbox
}

public_ip() {
  mock_cmd curl "echo $1"
}

# upnp_router EXTERNAL_IP (empty = no IGD answers)
upnp_router() {
  if [[ -z "$1" ]]; then
    mock_cmd upnpc 'echo "No IGD UPnP Device found on the network !"; exit 1'
  else
    mock_cmd upnpc "echo 'ExternalIPAddress = $1'"
  fi
}

reachability() {
  jq -r "$1" "${GVPN_STATE_DIR}/reachability.json"
}

# The UPnP answer comes back to an ephemeral port from the router's own address,
# which is not the multicast address the query went to, so the probe opens the
# reply path to the default gateway for its own duration and closes it again.
@test "opens the router reply path to the gateway only, and closes it" {
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  grep -qx "iptables -I INPUT 1 -i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -j ACCEPT" "${MOCK_LOG}"
  [ "$(grep -c '^iptables -I INPUT' "${MOCK_LOG}")" -eq 1 ]
  [ -z "$(rules_installed)" ]
}

# NAT-PMP is a unicast exchange with the gateway's port 5351, so the static
# conntrack rule already accepts its answer; opening 5351 as well would widen
# the hole for nothing.
@test "opens no rule for the NAT-PMP answer, which conntrack already accepts" {
  upnp_router ""
  mock_cmd natpmpc 'echo "Public IP address : 198.51.100.9"; exit 0'
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .router_external_ip)" = "198.51.100.9" ]
  run grep -- '--sport 5351' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# A probe killed with SIGKILL or cut off by a power failure leaves its rule
# behind, because no trap reaches either, and two such runs leave two. The next
# probe removes every one of them before it inserts its own, so the leftovers
# neither accumulate nor outlive the probe.
@test "rules killed probes left behind are replaced, not stacked" {
  printf '%s\n%s\n' "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^iptables -I INPUT' "${MOCK_LOG}")" -eq 1 ]
  [ -z "$(rules_installed)" ]
}

# A leftover can also name an address that is no longer the router (the gateway
# changed between the killed run and this one). The sweep deletes by the
# specification it reads out of the chain, not by the one this run would build.
@test "a leftover for a former gateway is removed too" {
  printf '%s\n' "-i lan0 -s 192.168.1.254 -p udp -m udp --sport 1900 -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^iptables -I INPUT' "${MOCK_LOG}")" -eq 1 ]
  [ -z "$(rules_installed)" ]
}

# A rule of this shape that carries a comment is not one this script wrote (it
# never adds one), but the sweep still has to take it: a comment's text cannot be
# told from rule syntax, so the sweep hands the rule back to iptables as it
# printed it and lets the parser decide.
@test "a reply-path rule with a comment is swept too" {
  echo "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -m comment --comment keep -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^iptables -I INPUT' "${MOCK_LOG}")" -eq 1 ]
  [ -z "$(rules_installed)" ]
}

# A comment is printed verbatim, so its words must not be read as this rule's
# interface: a rule for another interface that carries a real source port of its
# own is not the reply path, and sweeping it would cut that interface off.
@test "a comment that reads like the reply path is not swept" {
  printf '%s\n' \
    "-i lo -m comment --comment \"x -i lan0 \" -m udp --sport 1900 -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 5351 -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(rules_installed)" = "$(printf '%s\n' "-i lo -m comment --comment \"x -i lan0 \" -m udp --sport 1900 -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 5351 -j ACCEPT")" ]
}

# An unquoted comment is a single word, so a comment's text that ends in the
# words of another comment match is still a comment, not this rule's tail.
@test "a comment that reads like the tail is not swept" {
  printf '%s\n' \
    "-i lan0 -p tcp -m comment --comment \"x --sport 1900 -m comment --comment y\" -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(rules_installed)" = "-i lan0 -p tcp -m comment --comment \"x --sport 1900 -m comment --comment y\" -j ACCEPT" ]
}

# The sweep must leave every rule that is not the reply path where it is —
# including a rule for another source port of the same router.
@test "the sweep leaves rules that are not the reply path alone" {
  printf '%s\n' \
    "-i lo -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 5351 -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 19000 -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(rules_installed)" = "$(printf '%s\n' "-i lo -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 5351 -j ACCEPT" \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 19000 -j ACCEPT")" ]
}

# Two runs would sweep away each other's rule, so a probe holds a lock for its
# whole run: an operator running the script by hand waits for the timer's probe.
@test "a run holds the lock while it probes" {
  mock_cmd upnpc 'sleep 5; echo "ExternalIPAddress = 203.0.113.7"'
  "${LIBEXEC}/netprobe.sh" >/dev/null 2>&1 &
  local pid=$! held=1
  for _ in $(seq 1 100); do
    if ! flock -n "${GVPN_RUN_DIR}/netprobe.lock" true 2>/dev/null; then
      held=0
      break
    fi
    sleep 0.1
  done
  kill "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null || true
  [ "${held}" -eq 0 ]
}

# A chain that cannot be read is a warning, not the end of the probe: the
# reachability report is what this unit is for, and the next run sweeps the rule.
@test "a chain that cannot be read still records reachability" {
  mock_cmd iptables '
rules="${SANDBOX}/iptables.state"
case "${1:-}" in
  -I) { echo "${*/-I INPUT 1 /}"; cat "${rules}"; } > "${rules}.new"; mv "${rules}.new" "${rules}" ;;
  -S) exit 1 ;;
esac'
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "203.0.113.7" ]
  [[ "${output}" == *"could not read INPUT"* ]]
  # Nothing may be opened that could not be swept again.
  run grep -c '^iptables -I' "${MOCK_LOG}"
  [ "${output}" = "0" ]
}

# A chain that stops answering after the reply path was opened costs the sweep
# and nothing else: the report is written, the run exits 0, and the EXIT trap
# tries again.
@test "a chain that fails after the rule was opened still records reachability" {
  mock_cmd iptables '
rules="${SANDBOX}/iptables.state"
touch "${rules}"
case "${1:-}" in
  -I) { echo "${*/-I INPUT 1 /}"; cat "${rules}"; } > "${rules}.new"; mv "${rules}.new" "${rules}" ;;
  -S)
    if [[ -e "${SANDBOX}/opened" ]]; then exit 1; fi
    : > "${SANDBOX}/opened"
    while IFS= read -r line; do echo "-A INPUT ${line}"; done < "${rules}" ;;
esac'
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "203.0.113.7" ]
  [[ "${output}" == *"could not read INPUT"* ]]
  grep -qx 'self-ipset ' "${MOCK_LOG}"
}

# A specification that no longer matches — a rule an operator removed between the
# read and the delete — costs that one rule and not the rest of the sweep.
@test "a rule that vanished meanwhile does not block the others" {
  printf '%s\n%s\n' \
    "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -j ACCEPT" \
    "-i lan0 -s 192.168.1.254 -p udp -m udp --sport 1900 -j ACCEPT" \
    > "${SANDBOX}/iptables.state"
  mock_cmd iptables-restore '
rules="${SANDBOX}/iptables.state"
: > "${SANDBOX}/restore.batch"
while IFS= read -r line; do
  case "${line}" in
    -D\ INPUT\ *) echo "${line#-D INPUT }" >> "${SANDBOX}/restore.batch" ;;
  esac
done
# One rule is gone before its batch arrives, the way a concurrent removal leaves
# it; that batch applies nothing, and the next one still lands.
while IFS= read -r spec; do
  if [[ "${spec}" == *192.168.1.1* && ! -e "${SANDBOX}/vanished" ]]; then
    : > "${SANDBOX}/vanished"
    exit 1
  fi
done < "${SANDBOX}/restore.batch"
while IFS= read -r spec; do
  grep -vxF -- "${spec}" "${rules}" > "${rules}.new" || : > "${rules}.new"
  mv "${rules}.new" "${rules}"
done < "${SANDBOX}/restore.batch"'
  run bash -c 'source "$1"; router_replies_close 192.168.1.1' _ "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  # The one whose batch failed is still there; the other went, so one bad
  # specification cannot hold the sweep back.
  [ "$(rules_installed)" = "-i lan0 -s 192.168.1.1 -p udp -m udp --sport 1900 -j ACCEPT" ]
  [[ "${output}" == *"could not remove a router reply rule"* ]]
}

# A wait that is not a number falls back to the default instead of making flock
# fail, which would skip every probe and look like lock contention.
@test "an unusable lock wait falls back to the default" {
  echo "GVPN_NETPROBE_LOCK_WAIT_S=soon" >> "${GVPN_EXIT_OVERRIDES}"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "203.0.113.7" ]
  [[ "${output}" != *"another probe"* ]]
}

# The wait for the lock is bounded, so a run that cannot have the probe skips
# this tick instead of sitting in front of the operator's terminal, and it
# touches no rule on the way out.
@test "a run that cannot get the lock skips instead of waiting forever" {
  echo "GVPN_NETPROBE_LOCK_WAIT_S=1" >> "${GVPN_EXIT_OVERRIDES}"
  hold_lock "${GVPN_RUN_DIR}/netprobe.lock"
  start=${SECONDS}
  run "${LIBEXEC}/netprobe.sh"
  release_lock
  [ "${status}" -eq 0 ]
  (( SECONDS - start < 30 ))
  [[ "${output}" == *"another probe"* ]]
  run grep '^iptables' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The rule lives only for the probe; a stopped unit must not leave it behind.
@test "the reply path is closed on exit and on SIGTERM" {
  grep -q "trap 'router_replies_close || true' EXIT" "${LIBEXEC}/netprobe.sh"
  grep -q "trap 'router_replies_close || true; exit 1' INT TERM" "${LIBEXEC}/netprobe.sh"
}

# A LAN that is not up yet (no lan0, so `ip route` fails) must still produce a
# report: offline runs record an unknown address and exit 0.
@test "a failing route lookup still records reachability and exits 0" {
  mock_cmd ip '
case "$*" in
  *"route show default"*) exit 1 ;;
  *) echo "2: lan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic lan0" ;;
esac'
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "203.0.113.7" ]
  [ "$(reachability .checked_at)" = "2026-09-24T03:30:00Z" ]
  run grep '^iptables' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "opens no reply path when the device has no default gateway" {
  mock_cmd ip '
case "$*" in
  *"route show default"*) exit 0 ;;
  *) echo "2: lan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic lan0" ;;
esac'
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  run grep '^iptables' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "never requests a port mapping from the router" {
  mock_cmd natpmpc 'echo "Public IP address : 203.0.113.7"'
  run "${LIBEXEC}/netprobe.sh"
  grep -q 'upnpc -s' "${MOCK_LOG}"
  run grep -- ' -a' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "does not announce an address to hoprd" {
  run "${LIBEXEC}/netprobe.sh"
  [ ! -e "${GVPN_STATE_DIR}/hoprd-host.env" ]
  run grep 'hoprd' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refreshes the self-address ipset after recording reachability" {
  run "${LIBEXEC}/netprobe.sh"

  [ "${status}" -eq 0 ]
  grep -qx 'self-ipset ' "${MOCK_LOG}"
}

# The report an offline probe writes carries no address at all. The real
# self-ipset.sh has to create and swap the set from it anyway: the firewall
# loads iptables-restore afterwards and fails on a set that does not exist.
@test "offline: the real self-ipset creates the set from the report written" {
  unset GVPN_SELF_IPSET_BIN
  mock_cmd ipset
  mock_cmd curl 'exit 6'
  upnp_router ""

  run "${LIBEXEC}/netprobe.sh"

  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "null" ]
  [ "$(reachability .router_external_ip)" = "null" ]
  [[ "${output}" != *"failed to refresh self-address ipset"* ]]
  grep -qx 'ipset create gvpn-self hash:net family inet maxelem 16 -exist' "${MOCK_LOG}"
  grep -E -qx 'ipset swap gvpn-self-staging-[0-9]+ gvpn-self' "${MOCK_LOG}"
}

@test "records the router's external address from UPnP" {
  run "${LIBEXEC}/netprobe.sh"
  [ "$(reachability .router_external_ip)" = "203.0.113.7" ]
}

@test "falls back to NAT-PMP for the router's external address" {
  upnp_router ""
  mock_cmd natpmpc 'echo "Public IP address : 198.51.100.9"; exit 0'
  run "${LIBEXEC}/netprobe.sh"
  grep -qx 'natpmpc ' "${MOCK_LOG}"
  [ "$(reachability .router_external_ip)" = "198.51.100.9" ]
}

@test "records an unknown router address when neither protocol answers" {
  upnp_router ""
  run "${LIBEXEC}/netprobe.sh"
  [ "$(reachability .router_external_ip)" = "null" ]
}

@test "records the probe result in reachability.json" {
  run "${LIBEXEC}/netprobe.sh"
  [ "$(reachability .public_ip)" = "203.0.113.7" ]
  [ "$(reachability .lan_ip)" = "192.168.1.50" ]
  [ "$(reachability .router_external_ip)" = "203.0.113.7" ]
  [ "$(reachability .cgnat)" = "false" ]
  [ "$(reachability .checked_at)" = "2026-09-24T03:30:00Z" ]
  [ "$(reachability 'has("mapping")')" = "false" ]
}

@test "flags CGNAT when the router's external address differs from the public one" {
  upnp_router 100.72.1.1
  run "${LIBEXEC}/netprobe.sh"
  [ "$(reachability .cgnat)" = "true" ]
}

@test "classifies shared and private router WAN ranges at their boundaries" {
  local router nat
  while read -r router nat; do
    upnp_router "${router}"
    run "${LIBEXEC}/netprobe.sh"
    [ "${status}" -eq 0 ]
    [ "$(reachability .nat)" = "${nat}" ]
    [ "$(reachability .cgnat)" = "$([[ "${nat}" == cgnat ]] && echo true || echo false)" ]
  done <<'EOF'
100.63.255.255 unknown
100.64.0.0 cgnat
100.127.255.255 cgnat
100.128.0.0 unknown
9.255.255.255 unknown
10.0.0.0 double_nat
10.255.255.255 double_nat
11.0.0.0 unknown
172.15.255.255 unknown
172.16.0.0 double_nat
172.31.255.255 double_nat
172.32.0.0 unknown
192.167.255.255 unknown
192.168.0.0 double_nat
192.168.255.255 double_nat
192.169.0.0 unknown
EOF
}

@test "inconclusive router data remains unknown and preserves other report fields" {
  local router
  echo '{"fleet_note":"keep"}' > "${GVPN_STATE_DIR}/reachability.json"
  for router in '' 198.51.100.9 127.0.0.1 169.254.1.1; do
    upnp_router "${router}"
    run "${LIBEXEC}/netprobe.sh"
    [ "${status}" -eq 0 ]
    [ "$(reachability .nat)" = "unknown" ]
    [ "$(reachability .cgnat)" = "false" ]
    [ "$(reachability .fleet_note)" = "keep" ]
  done
}

@test "offline: records an unknown public address and does not fail the unit" {
  mock_cmd curl 'exit 6'
  upnp_router ""
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "null" ]
  [ "$(reachability .nat)" = "unknown" ]
}

@test "a router that never answers cannot stall the probe" {
  echo "GVPN_ROUTER_PROBE_TIMEOUT_S=1" >> "${GVPN_EXIT_OVERRIDES}"
  mock_cmd upnpc 'sleep 30'
  mock_cmd natpmpc 'sleep 30'
  start=${SECONDS}
  run "${LIBEXEC}/netprobe.sh"
  (( SECONDS - start < 10 ))
  [ "$(reachability .router_external_ip)" = "null" ]
}

@test "ignores a public IP answer that is not an IPv4 address" {
  mock_cmd curl 'echo "<html>rate limited</html>"'
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  [ "$(reachability .public_ip)" = "null" ]
}

# classify_nat PUBLIC_IP ROUTER_EXTERNAL_IP -> ok | cgnat | double_nat | unknown

@test "classify_nat: router external equals public address is ok" {
  run in_script "${LIBEXEC}/netprobe.sh" classify_nat 203.0.113.7 203.0.113.7
  [ "${output}" = "ok" ]
}

@test "classify_nat: public address inside 100.64.0.0/10 is cgnat" {
  run in_script "${LIBEXEC}/netprobe.sh" classify_nat 100.64.3.4 100.64.3.4
  [ "${output}" = "cgnat" ]
}

@test "classify_nat: router external in 100.64.0.0/10 behind a different public address is cgnat" {
  run in_script "${LIBEXEC}/netprobe.sh" classify_nat 203.0.113.7 100.72.1.1
  [ "${output}" = "cgnat" ]
}
