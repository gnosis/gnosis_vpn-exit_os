#!/usr/bin/env bats
# gvpn-exit-status: read-only system diagnostic for operators. Prints
# provisioning, Blokli, firewall, hoprd, WireGuard, reachability, CPU and
# netdata state; exits 1 when any check FAILs. The SSH MOTD points at it.

load helpers

NODE_ADDRESS="0x1234567890abcdef1234567890abcdef12345678"
SAFE="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
MODULE="0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
BLOKLI="https://blokli-test.example.org"
HOPRD_PID=4242

setup() {
  setup_sandbox
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/etc/hoprd.env.d"
  export GVPN_PROC_DIR="${SANDBOX}/proc"
  export GVPN_HOPRD_CFG="${SHARE}/hoprd.cfg.yaml"
  export UNIT_STATES="${SANDBOX}/units"
  export GVPN_CPUFREQ_DIR="${SANDBOX}/cpufreq"
  export GVPN_NET_CLASS="${SANDBOX}/net"
  mkdir -p "${GVPN_HOPRD_ENV_DIR}" "${GVPN_PROC_DIR}/${HOPRD_PID}" "${UNIT_STATES}"
  cpu_policy policy0 performance performance
  cpu_policy policy1 performance performance
  # One wired NIC, plus the virtual interfaces that must not be mistaken for
  # one: wggvpn and ifb-gvpn are ether too, without hardware behind them.
  wired_nic lan0
  virtual_nic wggvpn
  virtual_nic ifb-gvpn
  CLI="${ROOTFS}/usr/bin/gvpn-exit-status"

  mock_cmd id 'echo 0'
  # Units are active unless ${UNIT_STATES}/<unit> says otherwise.
  mock_cmd systemctl '
case "$1" in
  is-active) state="$(cat "${UNIT_STATES}/${*: -1}" 2>/dev/null || echo active)"; echo "${state}"; [[ "${state}" == active ]] ;;
  show)
    case "$*" in
      *MainPID*) cat "${UNIT_STATES}/mainpid" 2>/dev/null || echo 0 ;;
      *NRestarts*) echo 0 ;;
    esac ;;
esac'
  mock_cmd curl 'exit 0'
  mock_cmd bootc 'echo "{\"spec\":{\"image\":{\"image\":\"registry.example/gnosis-vpn-exit-os:canary\"}},\"status\":{\"booted\":{\"image\":{\"imageDigest\":\"sha256:booted\"}}}}"'
  mock_cmd hoprd 'echo "hoprd 5.0.2"'
  mock_cmd ip 'echo "2: lan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic lan0"'
  mock_cmd iptables '
case "$2" in
  FORWARD) printf "%s\n" "-P FORWARD DROP" "-A FORWARD -i wggvpn -j GVPN_PRIVATE" "-A FORWARD -i wggvpn -o lan0 -j ACCEPT" ;;
  INPUT) printf "%s\n" "-P INPUT DROP" "-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT" "-A INPUT -i wggvpn -j DROP" "-A INPUT -p tcp --dport 9091 -j ACCEPT" ;;
esac'
  mock_cmd ip6tables 'printf "%s\n" "-P INPUT DROP" "-P FORWARD DROP" "-P OUTPUT DROP"'
  mock_cmd ipset 'echo "Number of entries: 4321"'
  mock_cmd wg '
case "$3" in
  listen-port) echo 51820 ;;
  peers) printf "%s\n" peerkey1= peerkey2= ;;
esac'
  mock_cmd tc 'echo "qdisc htb 1: root refcnt 2 r2q 10 default 0x10"'
}

teardown() {
  teardown_sandbox
}

# wired_nic NAME: a sysfs entry for a NIC with hardware behind it and no udev
# device type, the way the kernel reports a wired NIC.
wired_nic() {
  mkdir -p "${GVPN_NET_CLASS}/$1/device"
  echo 1 > "${GVPN_NET_CLASS}/$1/type"
  printf 'INTERFACE=%s\nIFINDEX=2\n' "$1" > "${GVPN_NET_CLASS}/$1/uevent"
}

# virtual_nic NAME [ARPHRD_TYPE]: an interface without hardware behind it.
virtual_nic() {
  mkdir -p "${GVPN_NET_CLASS}/$1"
  echo "${2:-1}" > "${GVPN_NET_CLASS}/$1/type"
  printf 'INTERFACE=%s\nIFINDEX=9\n' "$1" > "${GVPN_NET_CLASS}/$1/uevent"
}

# typed_nic NAME DEVTYPE: a NIC with hardware behind it that udev types as
# something other than `ether` (a Wi-Fi card is `wlan`, an LTE modem in
# Ethernet mode `wwan`).
typed_nic() {
  wired_nic "$1"
  printf 'DEVTYPE=%s\nINTERFACE=%s\nIFINDEX=3\n' "$2" "$1" > "${GVPN_NET_CLASS}/$1/uevent"
}

# phy_nic NAME: a card the kernel reports without a device type but with an
# 802.11 phy, which systemd treats as wireless too.
phy_nic() {
  wired_nic "$1"
  mkdir -p "${GVPN_NET_CLASS}/$1/phy80211"
}

provision_device() {
  provision_sandbox
  # A provisioned device has measured its uplink at boot (capacity.sh).
  seed_capacity 200000 120000
  printf 'HOPRD_SAFE_ADDRESS=%s\nHOPRD_MODULE_ADDRESS=%s\nHOPRD_BLOKLI_URL=%s\n' "${SAFE}" "${MODULE}" "${BLOKLI}" \
    > "${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  cat > "${GVPN_IDENTITY_DIR}/provisioning.json" <<EOF
{"node_address": "${NODE_ADDRESS}", "peer_id": "12D3KooWPeer", "wg_public_key": "wgpub=",
 "support_public_key": "ssh-ed25519 AAAA", "safe_address": "${SAFE}", "module_address": "${MODULE}",
 "blokli_url": "${BLOKLI}", "serial": "SER8-0001", "support_port": null,
 "exit": {"gnosis_vpn_server": "172.30.0.1:8000", "wireguard_server": "172.30.0.1:51820", "location": "Zurich, CH"},
 "image_digest": "sha256:provisioned", "provisioned_at": "2026-09-24T00:00:00Z"}
EOF
  hoprd_running_with "HOPRD_BLOKLI_URL=${BLOKLI}"
}

# hoprd_running_with ENV_LINE...: hoprd.service's main process and its environment.
hoprd_running_with() {
  echo "${HOPRD_PID}" > "${UNIT_STATES}/mainpid"
  printf '%s\0' HOME=/var/lib/hoprd "$@" > "${GVPN_PROC_DIR}/${HOPRD_PID}/environ"
}

unit_state() {
  echo "$2" > "${UNIT_STATES}/$1"
}

# cpu_policy NAME GOVERNOR EPP: one cpufreq policy in the fake sysfs.
cpu_policy() {
  mkdir -p "${GVPN_CPUFREQ_DIR}/$1"
  echo "$2" > "${GVPN_CPUFREQ_DIR}/$1/scaling_governor"
  echo "$3" > "${GVPN_CPUFREQ_DIR}/$1/energy_performance_preference"
}

@test "unprovisioned: reports the state and skips the gated sections" {
  run "${CLI}"
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state:"*"unprovisioned"* ]]
  [[ "${output}" == *"== Blokli =="*"skipped (unprovisioned)"* ]]
  [[ "${output}" == *"== hoprd =="*"skipped (unprovisioned)"* ]]
  [[ "${output}" == *"== WireGuard =="*"skipped (unprovisioned)"* ]]
  ! grep -q '^curl .*healthyz' "${MOCK_LOG}"
}

# The .link file gives lan0 to the wired NIC and matches every wired NIC, so a
# second one (a dual-port board, a dock, a USB adapter) leaves the naming
# undefined. The virtual interfaces are ether too and must not count.
@test "network: one wired NIC is the lan0 candidate" {
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"lan0:"*"192.168.1.50"* ]]
  [[ "${output}" == *"wired NICs:"*"ok (lan0)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

# A Wi-Fi card the module blacklist does not cover is an ether device with an
# 802.11 phy; the .link file does not rename it, so it is no candidate, and a
# card the kernel types only through its phy is not one either.
@test "network: a wireless interface is not a wired NIC" {
  typed_nic wlp3s0 wlan
  phy_nic wlp4s0
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"wired NICs:"*"ok (lan0)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

# An LTE modem in Ethernet mode is `wwan` to udev, so the .link file leaves it
# alone and it must not be counted as a LAN candidate.
@test "network: a wwan modem is not a wired NIC" {
  typed_nic wwan0 wwan
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"wired NICs:"*"ok (lan0)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

@test "network: a second wired NIC warns that lan0 naming is undefined" {
  wired_nic enp4s0
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"wired NICs:"*"WARN (2 candidates: "* ]]
  [[ "${output}" == *"lan0 naming is undefined"* ]]
  [[ "${output}" == *"lan0 enp4s0"* || "${output}" == *"enp4s0 lan0"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 1 WARN"* ]]
}

@test "network: no wired NIC fails, because lan0 cannot be renamed into place" {
  rm -rf "${GVPN_NET_CLASS}/lan0"
  run "${CLI}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"wired NICs:"*"FAIL (none found"* ]]
}

@test "unprovisioned: firewall and netdata are still checked" {
  run "${CLI}"
  [[ "${output}" == *"gvpn-exit-firewall.service:"*"ok"* ]]
  [[ "${output}" == *"FORWARD isolation:"*"ok"* ]]
  [[ "${output}" == *"netdata.service:"*"ok"* ]]
}

@test "identity created but not finalized" {
  echo "{\"node_address\": \"${NODE_ADDRESS}\", \"peer_id\": \"12D3KooWPeer\"}" > "${GVPN_IDENTITY_DIR}/node.json"
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"identity created, not finalized"* ]]
  [[ "${output}" == *"node address:"*"${NODE_ADDRESS}"* ]]
}

@test "provisioned: prints the provisioning record and the update channel" {
  provision_device
  run "${CLI}"
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"state:"*"provisioned at 2026-09-24T00:00:00Z"* ]]
  [[ "${output}" == *"node address:"*"${NODE_ADDRESS}"* ]]
  [[ "${output}" == *"peer id:"*"12D3KooWPeer"* ]]
  [[ "${output}" == *"safe address:"*"${SAFE}"* ]]
  [[ "${output}" == *"module address:"*"${MODULE}"* ]]
  [[ "${output}" == *"serial:"*"SER8-0001"* ]]
  [[ "${output}" == *"location:"*"Zurich, CH"* ]]
  [[ "${output}" == *"image:"*"registry.example/gnosis-vpn-exit-os:canary"* ]]
  [[ "${output}" == *"booted digest:"*"sha256:booted"* ]]
  [[ "${output}" != *"support port:"* ]]
}

@test "provisioned: configured and used Blokli URL" {
  provision_device
  run "${CLI}"
  [[ "${output}" == *"configured:"*"${BLOKLI}"* ]]
  [[ "${output}" == *"used:"*"${BLOKLI} (hoprd pid ${HOPRD_PID})"* ]]
  [[ "${output}" == *"reachable:"*"ok"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

@test "hoprd running with a different Blokli URL is a warning" {
  provision_device
  hoprd_running_with "HOPRD_BLOKLI_URL=https://blokli-old.example"
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"used:"*"https://blokli-old.example"* ]]
  [[ "${output}" == *"consistency:"*"WARN"* ]]
}

@test "hoprd without HOPRD_BLOKLI_URL uses the image default" {
  provision_device
  hoprd_running_with
  run "${CLI}"
  [[ "${output}" == *"used:"*"https://blokli.example.org (image default)"* ]]
}

@test "hoprd not running: no used URL, the unit FAILs" {
  provision_device
  rm "${UNIT_STATES}/mainpid"
  unit_state hoprd.service failed
  run "${CLI}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"used:"*"hoprd not running"* ]]
  [[ "${output}" == *"hoprd.service:"*"FAIL (failed)"* ]]
}

@test "hoprd health: probes healthyz and reports the version" {
  provision_device
  echo 2 > "${GVPN_RUN_DIR}/hoprd-health.failures"
  run "${CLI}"
  grep -q 'curl .*http://127.0.0.1:3001/healthyz' "${MOCK_LOG}"
  [[ "${output}" == *"health:"*"ok"* ]]
  [[ "${output}" == *"version:"*"hoprd 5.0.2"* ]]
  [[ "${output}" == *"failed probes:"*"2"* ]]
}

@test "hoprd health endpoint down is a warning" {
  provision_device
  mock_cmd curl '[[ "$*" != *healthyz* ]]'
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"health:"*"WARN"* ]]
}

@test "WireGuard: server, interface, peers and shaping" {
  provision_device
  run "${CLI}"
  echo "${output}"
  grep -q 'curl .*http://172.30.0.1:8000/api/v1/ping' "${MOCK_LOG}"
  [[ "${output}" == *"gnosisvpn-server.service:"*"ok"* ]]
  [[ "${output}" == *"ping:"*"ok"* ]]
  [[ "${output}" == *"wggvpn:"*"ok (listening on 51820)"* ]]
  [[ "${output}" == *"peers:"*"2"* ]]
  [[ "${output}" == *"shaping wggvpn:"*"ok"* ]]
  [[ "${output}" == *"shaping ifb-gvpn:"*"ok"* ]]
}

@test "WireGuard interface down FAILs" {
  provision_device
  mock_cmd wg 'exit 1'
  run "${CLI}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"wggvpn:"*"FAIL"* ]]
}

@test "broken FORWARD isolation FAILs" {
  mock_cmd iptables '
case "$2" in
  FORWARD) printf "%s\n" "-P FORWARD DROP" "-A FORWARD -i wggvpn -o lan0 -j ACCEPT" "-A FORWARD -i wggvpn -j GVPN_PRIVATE" ;;
  INPUT) printf "%s\n" "-P INPUT DROP" "-A INPUT -s 10.128.0.0/24 -d 10.128.0.1/32 -i wggvpn -p icmp -m icmp --icmp-type 8 -j ACCEPT" "-A INPUT -i wggvpn -j DROP" ;;
esac'
  run "${CLI}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FORWARD isolation:"*"FAIL"* ]]
  [[ "${output}" == *"summary:"*"1 FAIL"* ]]
}

@test "INPUT without the client tunnel ping FAILs" {
  provision_device
  mock_cmd iptables '
case "$2" in
  FORWARD) printf "%s\n" "-P FORWARD DROP" "-A FORWARD -i wggvpn -j GVPN_PRIVATE" "-A FORWARD -i wggvpn -o lan0 -j ACCEPT" ;;
  INPUT) printf "%s\n" "-P INPUT DROP" "-A INPUT -i wggvpn -j DROP" ;;
esac'
  run "${CLI}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"client tunnel ping:"*"FAIL"* ]]
}

# The allowance is installed with wggvpn, so an unprovisioned device has none
# and must not be told its firewall is broken.
@test "an unprovisioned device skips the client tunnel ping" {
  mock_cmd iptables '
case "$2" in
  FORWARD) printf "%s\n" "-P FORWARD DROP" "-A FORWARD -i wggvpn -j GVPN_PRIVATE" "-A FORWARD -i wggvpn -o lan0 -j ACCEPT" ;;
  INPUT) printf "%s\n" "-P INPUT DROP" "-A INPUT -i wggvpn -j DROP" ;;
esac'
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"client tunnel ping:"*"skipped (unprovisioned)"* ]]
}

@test "firewall reports the blocklist size" {
  run "${CLI}"
  [[ "${output}" == *"blocklist:"*"ok (4321 entries)"* ]]
}

@test "reachability: a stale announced address is a warning" {
  provision_device
  printf 'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1\n' > "${GVPN_STATE_DIR}/hoprd-host.env"
  printf '{"public_ip":"203.0.113.7","nat":"ok","checked_at":"2026-09-24T03:30:00Z"}\n' > "${GVPN_STATE_DIR}/reachability.json"

  run "${CLI}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"== Reachability =="* ]]
  [[ "${output}" == *"announced:"*"8.8.4.4:9091"* ]]
  [[ "${output}" == *"observed:"*"203.0.113.7 (checked 2026-09-24T03:30:00Z)"* ]]
  [[ "${output}" == *"announced vs observed:"*"WARN"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 1 WARN"* ]]
}

@test "reachability: no drift while the announced address is the observed one" {
  provision_device
  printf 'HOPRD_HOST=203.0.113.7:9091\nHOPRD_ANNOUNCE=1\n' > "${GVPN_STATE_DIR}/hoprd-host.env"
  printf '{"public_ip":"203.0.113.7","nat":"ok"}\n' > "${GVPN_STATE_DIR}/reachability.json"

  run "${CLI}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"announced vs observed:"*"ok"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

@test "reachability: nothing to compare without an announcement or an observation" {
  run "${CLI}"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"== Reachability =="* ]]
  [[ "${output}" == *"announced:"*"none"* ]]
  [[ "${output}" == *"observed:"*"unknown"* ]]
  [[ "${output}" != *"announced vs observed"* ]]
}

@test "CPU: every policy on the performance governor is ok" {
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"== CPU =="* ]]
  [[ "${output}" == *"governor:"*"ok (performance on 2 policies)"* ]]
  [[ "${output}" == *"energy preference:"*"performance"* ]]
}

@test "CPU: a policy on another governor is a warning naming it" {
  cpu_policy policy1 powersave balance_performance
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"governor:"*"WARN (powersave on policy1)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 1 WARN"* ]]
}

@test "CPU: without cpufreq there is nothing to check" {
  rm -rf "${GVPN_CPUFREQ_DIR}"
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"governor:"*"n/a (no cpufreq)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

@test "netdata: probe and SSH tunnel link to the dashboard" {
  run "${CLI}"
  grep -q 'curl .*http://127.0.0.1:19999/api/v1/info' "${MOCK_LOG}"
  [[ "${output}" == *"dashboard:"*"ssh -L 19999:127.0.0.1:19999 devops@192.168.1.50, then http://127.0.0.1:19999"* ]]
}

@test "netdata tunnel uses the sudo user" {
  SUDO_USER=operator run "${CLI}"
  [[ "${output}" == *"ssh -L 19999:127.0.0.1:19999 operator@192.168.1.50"* ]]
}

@test "non-root: root-only checks show n/a" {
  provision_device
  mock_cmd id 'echo 1000'
  run "${CLI}"
  [[ "${output}" == *"not running as root"* ]]
  [[ "${output}" == *"used:"*"n/a (needs root)"* ]]
  [[ "${output}" == *"FORWARD isolation:"*"n/a (needs root)"* ]]
  [[ "${output}" == *"client tunnel ping:"*"n/a (needs root)"* ]]
  [[ "${output}" == *"wggvpn:"*"n/a (needs root)"* ]]
  ! grep -q '^iptables' "${MOCK_LOG}"
  ! grep -q '^wg' "${MOCK_LOG}"
}

@test "reports the measured uplink and the peer pool derived from it" {
  provision_device
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"== Capacity =="* ]]
  [[ "${output}" == *"aggregate:"*"30000 kbit/s"* ]]
  [[ "${output}" == *"peer ceiling:"*"10000 kbit/s"* ]]
  [[ "${output}" == *"peer guarantee:"*"5000 kbit/s"* ]]
  [[ "${output}" == *"peer slots:"*"6 (10.128.0.2-10.128.0.7)"* ]]
  [[ "${output}" == *"uplink:"*"ok (down 200000, up 120000 kbit/s)"* ]]
}

@test "warns when the capacity is assumed instead of measured" {
  provision_device
  rm -f "${GVPN_STATE_DIR}/capacity.env"
  run "${CLI}"
  [[ "${output}" == *"peer slots:"*"1 (10.128.0.2-10.128.0.2)"* ]]
  [[ "${output}" == *"aggregate:"*"7500 kbit/s"* ]]
  [[ "${output}" == *"uplink:"*"WARN (no sample, assuming the supported-environment floor)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 1 WARN"* ]]
}

@test "warns when the last probe failed and an older sample still applies" {
  provision_device
  seed_capacity 200000 120000
  sed -i 's/^GVPN_CAPACITY_ATTEMPT=ok/GVPN_CAPACITY_ATTEMPT=failed/' "${GVPN_STATE_DIR}/capacity.env"
  run "${CLI}"
  [[ "${output}" == *"uplink:"*"WARN (probe failed at 2026-10-01T03:00:00Z, using the sample from 2026-10-01T03:00:00Z)"* ]]
  [[ "${output}" == *"peer slots:"*"6 (10.128.0.2-10.128.0.7)"* ]]
}

@test "a boot without an uplink keeps the earlier sample without warning" {
  provision_device
  seed_capacity 200000 120000
  sed -i 's/^GVPN_CAPACITY_ATTEMPT=ok/GVPN_CAPACITY_ATTEMPT=skipped/' "${GVPN_STATE_DIR}/capacity.env"
  run "${CLI}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"uplink:"*"ok (probe skipped at 2026-10-01T03:00:00Z, sample from 2026-10-01T03:00:00Z)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 0 WARN"* ]]
}

@test "SSH MOTD points at the diagnostic" {
  local motd="${ROOTFS}/usr/lib/motd.d/50-gvpn-exit"
  [ -f "${motd}" ]
  [ ! -x "${motd}" ]
  grep -q 'sudo gvpn-exit-status' "${motd}"
}

@test "non-root without access to the identity: provisioning state unknown, not unprovisioned" {
  provision_device
  mock_cmd id 'echo 1000'
  chmod 000 "${GVPN_IDENTITY_DIR}"
  run "${CLI}"
  chmod 700 "${GVPN_IDENTITY_DIR}"
  echo "${output}"
  [[ "${output}" != *"unprovisioned"* ]]
  [[ "${output}" == *"state:"*"WARN (unknown, n/a (needs root))"* ]]
  [[ "${output}" == *"record:"*"n/a (needs root)"* ]]
  [[ "${output}" == *"== hoprd =="*"skipped (provisioning state unknown, use sudo)"* ]]
  [[ "${output}" == *"== WireGuard =="*"skipped (provisioning state unknown, use sudo)"* ]]
  [[ "${output}" == *"summary: 0 FAIL, 1 WARN"* ]]
}
