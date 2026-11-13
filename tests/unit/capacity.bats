#!/usr/bin/env bats
# capacity.sh measures the uplink at boot and caches the sample that lib.sh
# turns into the shaping aggregate and the peer pool. The probe is best effort:
# an expected failure keeps the last good sample and still exits 0, so the VPN
# server is never gated on the measurement.

load helpers

# The sleep mock advances the LAN port's byte counters by MOCK_RX_BPS and
# MOCK_TX_BPS per second it is asked to sleep, so a test sees traffic flow
# without waiting for it.
ADVANCE_COUNTERS='
stats="${GVPN_NET_CLASS}/lan0/statistics"
if [[ -f "${stats}/rx_bytes" ]]; then
  echo $(( $(< "${stats}/rx_bytes") + MOCK_RX_BPS * $1 )) > "${stats}/rx_bytes"
fi
if [[ -f "${stats}/tx_bytes" ]]; then
  echo $(( $(< "${stats}/tx_bytes") + MOCK_TX_BPS * $1 )) > "${stats}/tx_bytes"
fi'

# A transfer runs until capacity.sh stops it; the preflight answers with the
# headers Cloudflare sends: the edge's TCP statistics in Server-Timing (RTTs in
# microseconds) and the data centre in CF-RAY. Streams record their PID so a
# test can prove none is left. They close bats' fd 3 and stderr, so a leaked
# one cannot hold the test open.
CURL_OK='
case "$*" in
  *"__down?bytes=0"*)
    printf "HTTP/2 200\r\nServer-Timing: cfSpeedEdge;dur=9, cfSpeedWorker;dur=21\r\n"
    printf "CF-RAY: a5950ad75db85be0-LIS\r\n"
    printf "server-timing: cfL4;desc=\"?proto=TCP&rtt=3301&min_rtt=1352&rtt_var=1749&lost=0\"\r\n\r\n" ;;
  *) echo $$ >> "${SANDBOX}/streams"; exec "${REAL_SLEEP}" 37 2>/dev/null 3>&- ;;
esac'

setup() {
  setup_sandbox
  export GVPN_NOW=1790220600
  SCRIPT="${LIBEXEC}/capacity.sh"
  CACHE="${GVPN_STATE_DIR}/capacity.env"
  export TMPDIR="${SANDBOX}/tmp"
  mkdir -p "${TMPDIR}"
  # A device on a wired LAN with a default route.
  mock_cmd ip '
case "$*" in
  *"addr show"*) echo "2: lan0    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic lan0" ;;
  *"route show default"*) echo "default via 192.168.1.1 dev lan0 proto dhcp metric 100" ;;
esac'
  export GVPN_NET_CLASS="${SANDBOX}/net"
  mkdir -p "${GVPN_NET_CLASS}/lan0/statistics"
  echo 1000 > "${GVPN_NET_CLASS}/lan0/statistics/rx_bytes"
  echo 2000 > "${GVPN_NET_CLASS}/lan0/statistics/tx_bytes"
  # 25 MB/s and 15 MB/s on the wire are 200 and 120 Mbit/s.
  export MOCK_RX_BPS=25000000 MOCK_TX_BPS=15000000
  REAL_SLEEP="$(command -v sleep)"
  export REAL_SLEEP
  mock_cmd sleep "${ADVANCE_COUNTERS}"
  mock_cmd curl "${CURL_OK}"
}

teardown() {
  teardown_sandbox
}

cache_field() {
  sed -n "s/^$1=//p" "${CACHE}"
}

transfers() {
  grep -c "^curl .*$1" "${MOCK_LOG}" || true
}

@test "caches both directions of the measurement in kbit/s" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_SCHEMA)" = "1" ]
  [ "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" = "200000" ]
  [ "$(cache_field GVPN_CAPACITY_UP_KBIT)" = "120000" ]
  [ "$(cache_field GVPN_CAPACITY_MEASURED_AT)" = "2026-09-24T03:30:00Z" ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "ok" ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT_AT)" = "2026-09-24T03:30:00Z" ]
}

@test "reports the capacity the fresh sample yields" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  # 200/120 Mbit/s -> the smaller direction over four -> 30 Mbit/s, six slots.
  [[ "${output}" == *"peer aggregate 30000kbit, 6 slot(s)"* ]]
}

@test "names the endpoint, its data centre and the edge's minimum RTT" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"via speed.cloudflare.com LIS (1.4 ms)"* ]]
}

@test "measures an endpoint that sends no Cloudflare headers" {
  echo 'GVPN_CAPACITY_URL=https://speed.example.net' > "${GVPN_EXIT_OVERRIDES}"
  mock_cmd curl '
case "$*" in
  *"__down?bytes=0"*) printf "HTTP/1.1 200 OK\r\n\r\n"; exit 0 ;;
esac
'"${CURL_OK}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "ok" ]
  [[ "${output}" == *"via speed.example.net; peer aggregate"* ]]
}

@test "runs parallel downloads and uploads against Cloudflare's speed test" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(transfers 'https://speed.cloudflare.com/__down?bytes=[1-9]')" -eq 4 ]
  [ "$(transfers 'https://speed.cloudflare.com/__up')" -eq 4 ]
}

# An upload is a POST of the payload file on a reused connection, without the
# 100-continue round trip that would idle the stream between requests.
@test "uploads post the payload file without waiting for 100-continue" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local line
  while IFS= read -r line; do
    [[ "${line}" == *" -H Expect: -X POST -T ${TMPDIR}/"*" https://speed.cloudflare.com/__up?n=[1-1000]" ]]
    [[ "${line}" == *" --fail --fail-early --proto =https "* ]]
  done < <(grep '^curl .*__up' "${MOCK_LOG}")
  [ "$(grep -c '^curl .* -X POST .*__down' "${MOCK_LOG}")" -eq 0 ]
}

# Cloudflare answers 403 for a download of 100 MB or more; a rejected request
# would end the stream before the window closes.
@test "keeps every download request under Cloudflare's size cap" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local bytes
  for bytes in $(grep -o '__down?bytes=[0-9]*' "${MOCK_LOG}" | cut -d= -f2); do
    (( bytes < 100000000 ))
  done
}

# Slow start must not count: the rate is the window after the warm-up, so a
# probe that also counted the warm-up would report more than the link carries.
@test "measures only the window after the warm-up" {
  printf 'GVPN_CAPACITY_WARMUP_S=2\nGVPN_CAPACITY_WINDOW_S=5\n' > "${GVPN_EXIT_OVERRIDES}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(grep '^sleep ' "${MOCK_LOG}" | tr '\n' ' ')" = "sleep 2 sleep 5 sleep 2 sleep 5 " ]
  [ "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" = "200000" ]
  [ "$(cache_field GVPN_CAPACITY_UP_KBIT)" = "120000" ]
}

@test "runs the configured number of streams" {
  echo 'GVPN_CAPACITY_STREAMS=2' > "${GVPN_EXIT_OVERRIDES}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(transfers '__down?bytes=[1-9]')" -eq 2 ]
  [ "$(transfers '__up')" -eq 2 ]
}

@test "measures against the endpoint configured through GVPN_CAPACITY_URL" {
  echo 'GVPN_CAPACITY_URL=https://speed.example.net:8443/probe' > "${GVPN_EXIT_OVERRIDES}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "ok" ]
  ! grep -q cloudflare "${MOCK_LOG}"
  [ "$(transfers 'https://speed.example.net:8443/probe/__up')" -eq 4 ]
  [[ "${output}" == *"via speed.example.net:8443"* ]]
}

@test "refuses an endpoint that is not a plain https base URL" {
  local url
  for url in http://speed.example.net 'https://speed.example.net/[1-9]' 'https://speed.example.net/?x=1'; do
    echo "GVPN_CAPACITY_URL=${url}" > "${GVPN_EXIT_OVERRIDES}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
    [[ "${output}" == *"GVPN_CAPACITY_URL=${url} is not an https base URL"* ]]
  done
  ! grep -q '^curl ' "${MOCK_LOG}"
}

@test "refuses stream counts and durations that are not small positive integers" {
  local knob
  for knob in GVPN_CAPACITY_STREAMS=0 GVPN_CAPACITY_WARMUP_S=x GVPN_CAPACITY_WINDOW_S=0 GVPN_CAPACITY_STREAMS=100; do
    echo "${knob}" > "${GVPN_EXIT_OVERRIDES}"
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
    [[ "${output}" == *"${knob} is not"* ]]
  done
  ! grep -q '^curl ' "${MOCK_LOG}"
}

@test "does not saturate the link when the endpoint is unreachable" {
  mock_cmd curl 'exit 7'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [ "$(transfers '__down?bytes=[1-9]')" -eq 0 ]
  [ "$(transfers '__up')" -eq 0 ]
}

# A rejected or stalled request ends its stream, which leaves part of the
# window idle: the sample would understate the link.
@test "fails when a stream ends before the window closes" {
  mock_cmd sleep "${ADVANCE_COUNTERS}"'
"${REAL_SLEEP}" 0.3'
  mock_cmd curl '
case "$*" in
  *"__up"*) exit 22 ;;
esac
'"${CURL_OK}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [ -z "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" ]
  [[ "${output}" == *"upload: a stream ended before the window closed"* ]]
}

@test "stops every stream and removes the upload payload" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(wc -l < "${SANDBOX}/streams")" -eq 8 ]
  local pid
  while read -r pid; do
    ! kill -0 "${pid}" 2>/dev/null
  done < "${SANDBOX}/streams"
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "rejects a window in which nothing was transferred" {
  mock_cmd sleep 'exit 0'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [ -z "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" ]
}

@test "rejects an implausible speed beyond the sanity bound" {
  export MOCK_RX_BPS=2000000000000
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
}

# A probe that completes on a link throttled to a trickle measured something,
# but not the link the device normally has.
@test "a completed probe below the plausible minimum keeps the last good sample" {
  seed_capacity 200000 120000
  # 50 kB/s on the wire is 400 kbit/s.
  export MOCK_TX_BPS=50000
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [ "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" = "200000" ]
  [ "$(cache_field GVPN_CAPACITY_UP_KBIT)" = "120000" ]
  [ "$(cache_field GVPN_CAPACITY_MEASURED_AT)" = "2026-10-01T03:00:00Z" ]
  [[ "${output}" == *"down=200000kbit up=400kbit is below GVPN_CAPACITY_MIN_KBIT=1000"* ]]
}

@test "a slow first probe records no sample" {
  export MOCK_RX_BPS=50000
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [ -z "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" ]
  [[ "${output}" == *"no sample yet"* ]]
}

@test "refuses a minimum rate that is not a rate before loading the link" {
  echo 'GVPN_CAPACITY_MIN_KBIT=none' > "${GVPN_EXIT_OVERRIDES}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [[ "${output}" == *"GVPN_CAPACITY_MIN_KBIT=none is not a rate in kbit/s"* ]]
  ! grep -q '^curl ' "${MOCK_LOG}"
}

@test "fails when the LAN port's byte counter cannot be read" {
  rm "${GVPN_NET_CLASS}/lan0/statistics/tx_bytes"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [ -z "$(cache_field GVPN_CAPACITY_UP_KBIT)" ]
  [[ "${output}" == *"upload: cannot read the tx_bytes counter of lan0"* ]]
}

@test "writes a 0644 cache in one rename and leaves nothing behind" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(stat -c %a "${CACHE}")" = "644" ]
  [ "$(ls "${GVPN_STATE_DIR}")" = "capacity.env" ]
}

@test "skips the probe without an IPv4 address on the uplink" {
  mock_cmd ip 'case "$*" in *"route show default"*) echo "default via 192.168.1.1 dev lan0" ;; esac'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "skipped" ]
  [ -z "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" ]
  ! grep -q '^curl ' "${MOCK_LOG}"
  [[ "${output}" == *"skipping the capacity probe"* ]]
}

@test "skips the probe without a default route on the uplink" {
  mock_cmd ip 'case "$*" in *"addr show"*) echo "2: lan0    inet 192.168.1.50/24 scope global dynamic lan0" ;; esac'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "skipped" ]
  ! grep -q '^curl ' "${MOCK_LOG}"
}

@test "a skipped probe keeps the last good sample" {
  seed_capacity 200000 120000
  mock_cmd ip 'exit 0'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" = "200000" ]
  [ "$(cache_field GVPN_CAPACITY_UP_KBIT)" = "120000" ]
  [ "$(cache_field GVPN_CAPACITY_MEASURED_AT)" = "2026-10-01T03:00:00Z" ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "skipped" ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT_AT)" = "2026-09-24T03:30:00Z" ]
}

# A pinned aggregate is what the device shapes to, so a fresh sample would not
# be used: measuring the link would cost the transfer and prove nothing.
@test "skips the probe when the aggregate is pinned" {
  seed_capacity 200000 120000
  echo 'GVPN_PEER_SHAPING_AGGREGATE_KBIT=20000' > "${GVPN_EXIT_OVERRIDES}"
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "skipped" ]
  [ "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" = "200000" ]
  [ "$(cache_field GVPN_CAPACITY_MEASURED_AT)" = "2026-10-01T03:00:00Z" ]
  ! grep -q '^curl ' "${MOCK_LOG}"
  [[ "${output}" == *"pinned"* ]]
}

@test "a failed probe keeps the last good sample and exits 0" {
  seed_capacity 200000 120000
  mock_cmd curl 'exit 7'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" = "200000" ]
  [ "$(cache_field GVPN_CAPACITY_MEASURED_AT)" = "2026-10-01T03:00:00Z" ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [[ "${output}" == *"keeping the sample from 2026-10-01T03:00:00Z"* ]]
}

@test "a failed probe without a sample records that nothing was measured" {
  mock_cmd curl 'exit 7'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ -z "$(cache_field GVPN_CAPACITY_DOWN_KBIT)" ]
  [ -z "$(cache_field GVPN_CAPACITY_MEASURED_AT)" ]
  [ "$(cache_field GVPN_CAPACITY_ATTEMPT)" = "failed" ]
  [[ "${output}" == *"no sample yet"* ]]
}

@test "fails loudly when the cache cannot be written" {
  rmdir "${GVPN_STATE_DIR}"
  run bash "${SCRIPT}"
  [ "${status}" -ne 0 ]
}
