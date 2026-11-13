#!/usr/bin/env bats
# greenboot scripts: every gvpn check passes on an unprovisioned device, and
# the red/green hooks keep the rejected-digest and snapshot bookkeeping.

load helpers

GREENBOOT="${BATS_TEST_DIRNAME}/../../image/rootfs/usr/lib/greenboot"

setup() {
  setup_sandbox
  export GVPN_LIBEXEC_DIR="${LIBEXEC}"
  export GVPN_HOPRD_V4_SNAPSHOTS="${SANDBOX}/v4-snapshots"
  mock_cmd bootc 'echo "{\"status\":{\"booted\":{\"image\":{\"imageDigest\":\"sha256:booted\"}},\"rollback\":{\"image\":{\"imageDigest\":\"sha256:rollback\"}},\"staged\":null}}"'
}

teardown() {
  teardown_sandbox
}

# 10-gvpn-units on a provisioned device: every unit active without restarts
# and Blokli answering, unless a test changes ${UNIT_STATES}/<unit> (state),
# <unit>.restarts (NRestarts) or touches <unit>.restarts.climbing (one more
# restart per lookup, a crash loop).
units_check_setup() {
  provision_sandbox
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/etc/hoprd.env.d"
  export UNIT_STATES="${SANDBOX}/units"
  export GVPN_UNITS_TIMEOUT_S=1
  mkdir -p "${GVPN_HOPRD_ENV_DIR}" "${UNIT_STATES}"
  echo "HOPRD_BLOKLI_URL=https://blokli.example" > "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  mock_cmd systemctl '
case "$1" in
  is-active) [[ "$(cat "${UNIT_STATES}/${*: -1}" 2>/dev/null || echo active)" == active ]] ;;
  show)
    f="${UNIT_STATES}/${*: -1}.restarts"
    n="$(cat "${f}" 2>/dev/null || echo 0)"
    echo "${n}"
    if [[ -e "${f}.climbing" ]]; then echo $((n + 1)) > "${f}"; fi ;;
esac'
  mock_cmd curl
  mock_cmd sleep
  UNITS_CHECK="${GREENBOOT}/check/required.d/10-gvpn-units.sh"
}

@test "the units check reports a pending v4 to v5 migration instead of a red boot" {
  units_check_setup
  rm "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  run "${UNITS_CHECK}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"hoprd v5 is not configured yet"* ]]
}

@test "every required and wanted check skips on an unprovisioned device" {
  for check in "${GREENBOOT}"/check/required.d/*.sh "${GREENBOOT}"/check/wanted.d/*.sh; do
    run "${check}"
    [ "${status}" -eq 0 ] || { echo "${check}: ${output}"; false; }
  done
}

@test "every gvpn check that inspects the system is gated on provisioning" {
  for check in "${GREENBOOT}"/check/required.d/[1-9]*.sh "${GREENBOOT}"/check/wanted.d/*.sh; do
    grep -q 'if ! is_provisioned; then' "${check}" || { echo "${check} is not gated"; false; }
  done
}

@test "no check expects inbound reachability (hoprd is outbound-only)" {
  run grep -l '\.reachable' "${GREENBOOT}"/check/required.d/*.sh "${GREENBOOT}"/check/wanted.d/*.sh
  [ "${status}" -eq 1 ]
}

@test "red.d records the booted digest as rejected" {
  run "${GREENBOOT}/red.d/10-gvpn-record-rejection.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'sha256:booted' "${GVPN_STATE_DIR}/rejected-digests"
}

@test "green.d prunes snapshots of deployments bootc no longer has" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback" "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone"
  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"
  [ "${status}" -eq 0 ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback" ]
  [ ! -e "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone" ]
}

@test "green.d prunes nothing when bootc status cannot be read" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback"
  mock_cmd bootc 'echo "bootc: transient error" >&2; exit 1'
  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not pruning"* ]]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:rollback" ]
}

@test "green.d prunes nothing when bootc reports no booted deployment" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted"
  mock_cmd bootc 'echo "{\"status\":{\"booted\":null}}"'
  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"
  [ "${status}" -ne 0 ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" ]
}

# update-apply.sh copies the live data into <digest>.tmp and holds the update
# lock for the whole run, so a .tmp directory is a snapshot in progress while
# the lock is taken, not a stale one.
@test "green.d leaves the snapshot copy update-apply is writing alone" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  export GVPN_UPDATE_LOCK="${SANDBOX}/update.lock"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone" \
    "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted.tmp"
  hold_lock "${GVPN_UPDATE_LOCK}"
  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"
  release_lock
  [ "${status}" -eq 0 ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted.tmp" ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" ]
  [ ! -e "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone" ]
}

# The redirection that hides a lock file the hook cannot open must cover the
# open only: a bare exec would send every later error to /dev/null as well.
@test "green.d still reports a failure after the lock open" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  export GVPN_UPDATE_LOCK="${SANDBOX}/update.lock"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted"
  mock_cmd flock 'echo "flock: cannot lock" >&2; exit 1'

  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"flock: cannot lock"* ]]
}

# The keep list is read after the lock is taken, so a staging that completes
# while the lock is being taken is seen.
@test "green.d reads the keep list after taking the update lock" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  export GVPN_UPDATE_LOCK="${SANDBOX}/update.lock"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted"
  mock_cmd flock

  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"

  [ "${status}" -eq 0 ]
  [ "$(grep -n '^flock -n 9' "${MOCK_LOG}" | head -1 | cut -d: -f1)" \
    -lt "$(grep -n '^bootc ' "${MOCK_LOG}" | head -1 | cut -d: -f1)" ]
}

@test "green.d prunes a snapshot copy nobody is writing" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  export GVPN_UPDATE_LOCK="${SANDBOX}/update.lock"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone.tmp"
  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"
  [ "${status}" -eq 0 ]
  [ -d "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" ]
  [ ! -e "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone.tmp" ]
}

# The lock is what keeps update-apply.sh from copying into a directory the prune
# removes, so it has to be held while the removal runs, not only while the
# decision is made. A mock rm reports whether the lock was free at that moment.
@test "green.d holds the update lock while it removes a snapshot" {
  export GVPN_HOPRD_SNAPSHOTS="${SANDBOX}/snapshots"
  export GVPN_UPDATE_LOCK="${SANDBOX}/update.lock"
  mkdir -p "${GVPN_HOPRD_SNAPSHOTS}/sha256:booted" "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone"
  real_rm="$(type -P rm)"
  mock_cmd rm '
if flock -n "${GVPN_UPDATE_LOCK}" true; then
  echo free >> "'"${SANDBOX}"'/lock-state"
else
  echo held >> "'"${SANDBOX}"'/lock-state"
fi
'"${real_rm}"' "$@"'

  run "${GREENBOOT}/green.d/20-gvpn-prune-snapshots.sh"

  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_HOPRD_SNAPSHOTS}/sha256:gone" ]
  [ "$(< "${SANDBOX}/lock-state")" = "held" ]
}

# The wanted check logs the host it probes; an operator whose uplink resolves
# another name can point it there.
@test "wanted DNS check resolves the host the knob names" {
  provision_sandbox
  printf 'GVPN_DNS_PROBE_HOST=dns-probe.example\n' > "${GVPN_EXIT_OVERRIDES}"
  mock_cmd ip 'echo "default via 192.168.1.1 dev lan0"'
  mock_cmd getent
  run "${GREENBOOT}/check/wanted.d/10-gvpn-network.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'getent hosts dns-probe.example' "${MOCK_LOG}"
  [[ "${output}" == *"default route and DNS ok"* ]]
}

@test "wanted DNS check resolves the image default without an override" {
  provision_sandbox
  mock_cmd ip 'echo "default via 192.168.1.1 dev lan0"'
  mock_cmd getent
  run "${GREENBOOT}/check/wanted.d/10-gvpn-network.sh"
  [ "${status}" -eq 0 ]
  grep -qx 'getent hosts hub.hoprnet.org' "${MOCK_LOG}"
}

@test "wanted DNS check fails and names the host that does not resolve" {
  provision_sandbox
  mock_cmd ip 'echo "default via 192.168.1.1 dev lan0"'
  mock_cmd getent 'exit 2'
  run "${GREENBOOT}/check/wanted.d/10-gvpn-network.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"DNS does not resolve hub.hoprnet.org"* ]]
}

# 20-gvpn-server and 40-gvpn-shaping run against a Type=simple unit that brings
# the API and the shaping trees up after it starts. With GVPN_WAIT_INTERVAL_S=0
# the tests poll without waiting.
server_check_setup() {
  provision_sandbox
  export GVPN_SERVER_RUN_DIR="${SANDBOX}/gnosisvpn-server"
  export GVPN_WAIT_INTERVAL_S=0
  mkdir -p "${GVPN_SERVER_RUN_DIR}"
  : > "${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
  chmod 0600 "${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
  SERVER_CHECK="${GREENBOOT}/check/required.d/20-gvpn-server.sh"
  SHAPING_CHECK="${GREENBOOT}/check/required.d/40-gvpn-shaping.sh"
}

# 30-gvpn-firewall runs after gnosisvpn-server is active, but the tunnel-ping
# allowance appears only when wg-quick's PostUp has run.
firewall_check_setup() {
  provision_sandbox
  export GVPN_WAIT_INTERVAL_S=0
  mock_cmd ipset
  mock_cmd ip6tables 'printf "%s\n" "-P INPUT DROP" "-P FORWARD DROP" "-P OUTPUT DROP"'
  FIREWALL_CHECK="${GREENBOOT}/check/required.d/30-gvpn-firewall.sh"
}

@test "firewall: waits for the ping allowance the hooks install" {
  firewall_check_setup
  export GVPN_READY_TIMEOUT_S=10
  # The isolation rule is there from the start; the allowance appears on the
  # third listing, i.e. after the first wait attempt.
  mock_cmd iptables '
case "$2" in
  FORWARD) printf "%s\n" "-P FORWARD DROP" "-A FORWARD -i wggvpn -j GVPN_PRIVATE" ;;
  GVPN_PRIVATE) printf "%s\n" "-A GVPN_PRIVATE -m set --match-set gvpn-self dst -j DROP" ;;
  INPUT)
    n="$(cat "'"${SANDBOX}"'/input-calls" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "${n}" > "'"${SANDBOX}"'/input-calls"
    if (( n >= 3 )); then
      printf "%s\n" "-P INPUT DROP" "-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT" "-A INPUT -i wggvpn -j DROP"
    else
      printf "%s\n" "-P INPUT DROP" "-A INPUT -i wggvpn -j DROP"
    fi ;;
esac'

  run "${FIREWALL_CHECK}"

  [ "${status}" -eq 0 ]
  [ "$(grep -c '^iptables -S INPUT' "${MOCK_LOG}")" -eq 3 ]
  [[ "${output}" == *"firewall isolation in place"* ]]
}

@test "firewall: an allowance that never appears still fails the check" {
  firewall_check_setup
  export GVPN_READY_TIMEOUT_S=0
  mock_cmd iptables '
case "$2" in
  FORWARD) printf "%s\n" "-P FORWARD DROP" "-A FORWARD -i wggvpn -j GVPN_PRIVATE" ;;
  GVPN_PRIVATE) printf "%s\n" "-A GVPN_PRIVATE -m set --match-set gvpn-self dst -j DROP" ;;
  INPUT) printf "%s\n" "-P INPUT DROP" "-A INPUT -i wggvpn -j DROP" ;;
esac'

  run "${FIREWALL_CHECK}"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"tunnel verification ping"* ]]
}

@test "server: waits for the API and the interface instead of probing once" {
  server_check_setup
  export GVPN_READY_TIMEOUT_S=10
  # The first probe finds no API yet, the second does.
  mock_cmd curl '
if [[ -e "'"${SANDBOX}"'/probed" ]]; then exit 0; fi
: > "'"${SANDBOX}"'/probed"
exit 7'
  mock_cmd wg 'echo 51820'
  run "${SERVER_CHECK}"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^curl .*api/v1/ping' "${MOCK_LOG}")" -eq 2 ]
  [[ "${output}" == *"gnosis_vpn-server up"* ]]
}

@test "server: a server that never becomes ready fails the check with the reason" {
  server_check_setup
  export GVPN_READY_TIMEOUT_S=0
  mock_cmd curl 'exit 7'
  mock_cmd wg 'echo 51820'
  run "${SERVER_CHECK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not answer"* ]]
}

@test "server: a wrong interface port or key mode still fails" {
  server_check_setup
  export GVPN_READY_TIMEOUT_S=0
  mock_cmd curl
  mock_cmd wg 'echo 51821'
  run "${SERVER_CHECK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"wggvpn listens on 51821, expected 51820"* ]]
  mock_cmd wg 'echo 51820'
  chmod 0644 "${GVPN_SERVER_RUN_DIR}/wggvpn.conf"
  run "${SERVER_CHECK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"is not mode 0600"* ]]
}

@test "shaping: waits for both trees instead of probing once" {
  server_check_setup
  export GVPN_READY_TIMEOUT_S=10
  # wggvpn's tree appears only on the second look.
  mock_cmd tc '
if [[ "$*" == *"dev wggvpn root"* && ! -e "'"${SANDBOX}"'/wggvpn-shaped" ]]; then
  : > "'"${SANDBOX}"'/wggvpn-shaped"
  exit 0
fi
echo "qdisc htb 1: root refcnt 2 r2q 10"'
  mock_cmd ip 'echo "3: ifb-gvpn: <BROADCAST,UP> mtu 1500"'
  run "${SHAPING_CHECK}"
  [ "${status}" -eq 0 ]
  [ "$(grep -c 'tc qdisc show dev wggvpn root' "${MOCK_LOG}")" -eq 2 ]
  [[ "${output}" == *"shaping in place"* ]]
}

@test "shaping: a missing tree fails the check with the reason" {
  server_check_setup
  export GVPN_READY_TIMEOUT_S=0
  mock_cmd tc 'exit 0'
  mock_cmd ip 'echo "3: ifb-gvpn: <BROADCAST,UP> mtu 1500"'
  run "${SHAPING_CHECK}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no htb root on wggvpn"* ]]
}

@test "units: passes when every unit is up and hoprd stays up" {
  units_check_setup
  run "${UNITS_CHECK}"
  [ "${status}" -eq 0 ]
  grep -qx 'sleep 60' "${MOCK_LOG}"
}

@test "units: judges hoprd only after Blokli answered hoprd's startup query" {
  units_check_setup
  run "${UNITS_CHECK}"
  grep -q '^curl .*https://blokli.example/graphql$' "${MOCK_LOG}"
}

@test "units: hoprd retrying while Blokli does not answer is no software failure" {
  units_check_setup
  mock_cmd curl 'exit 7'
  echo activating > "${UNIT_STATES}/hoprd.service"
  echo 6 > "${UNIT_STATES}/hoprd.service.restarts"
  run "${UNITS_CHECK}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Blokli https://blokli.example does not answer"* ]]
}

@test "units: hoprd restarts from before Blokli answered do not fail a hoprd that stays up" {
  units_check_setup
  echo 3 > "${UNIT_STATES}/hoprd.service.restarts"
  run "${UNITS_CHECK}"
  [ "${status}" -eq 0 ]
}

@test "units: hoprd crash-looping while Blokli answers fails the boot" {
  units_check_setup
  echo 1 > "${UNIT_STATES}/hoprd.service.restarts"
  touch "${UNIT_STATES}/hoprd.service.restarts.climbing"
  run "${UNITS_CHECK}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"hoprd.service"* ]]
}

@test "units: hoprd down while Blokli answers fails the boot" {
  units_check_setup
  echo failed > "${UNIT_STATES}/hoprd.service"
  run "${UNITS_CHECK}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"hoprd.service"* ]]
}

@test "units: a gnosisvpn-server restart fails the boot, Blokli or not" {
  units_check_setup
  mock_cmd curl 'exit 7'
  echo 1 > "${UNIT_STATES}/gnosisvpn-server.service.restarts"
  run "${UNITS_CHECK}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"gnosisvpn-server.service restarted 1 times"* ]]
}

@test "wanted Blokli check asks the same GraphQL question as the units check" {
  units_check_setup
  mock_cmd curl 'exit 22'
  run "${GREENBOOT}/check/wanted.d/20-gvpn-blokli.sh"
  [ "${status}" -eq 1 ]
  grep -q '^curl .*https://blokli.example/graphql$' "${MOCK_LOG}"
}
