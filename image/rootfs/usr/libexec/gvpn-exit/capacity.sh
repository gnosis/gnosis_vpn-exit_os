#!/usr/bin/env bash
# gvpn-exit-capacity.service (once per provisioned boot, before the VPN server).
#
# Measures the uplink against Cloudflare's speed test endpoints
# (GVPN_CAPACITY_URL) and caches the sample in state/capacity.env. lib.sh turns
# that sample into the shaping aggregate and the peer pool (see exit.env): the
# exit's VPN traffic gets one GVPN_UPLINK_SHARE_DIVISOR of the measured link,
# and every concurrent client is admitted against GVPN_PEER_MIN_SHARE_KBIT of
# that share.
#
# The method matters: a probe that opens a few short-lived connections never
# leaves TCP slow start at a high RTT and under-reports a healthy line: the
# transfer ends while the congestion window is still growing, so its average
# rate is far below what the link carries. Each direction therefore runs
# GVPN_CAPACITY_STREAMS parallel
# streams of back-to-back requests on reused connections, skips the first
# GVPN_CAPACITY_WARMUP_S seconds and counts the bytes the LAN port moves in the
# next GVPN_CAPACITY_WINDOW_S seconds. Cloudflare's anycast network answers
# from its nearest data centre, so there is no server list to get wrong.
#
# The probe is best effort and never keeps the VPN from coming up:
# - the peer aggregate is pinned in /etc/gvpn-exit/exit.env: skip, because the
#   sample is not what the device shapes to;
# - no IPv4 address or default route on the LAN port: skip, keep the last
#   sample, and do not start transfers on a device that is offline;
# - an unreachable endpoint, a stream that ends before the window closes, an
#   unreadable byte counter or an implausible rate (beyond the sanity bound, or
#   below GVPN_CAPACITY_MIN_KBIT in either direction): keep the last good sample;
# - no sample at all: lib.sh falls back to GVPN_PEER_CAPACITY_FALLBACK_KBIT,
#   the supported-environment floor.
# Every outcome is recorded in the cache for gvpn-exit-status and the
# heartbeat, and an expected failure still exits 0 so the unit does not gate
# the server (gnosisvpn-server.service only Wants= this unit).
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

# Cloudflare answers 403 for a download of 100 MB or more. 50 MB requests stay
# below that cap and are long enough that the next request on the same
# connection starts with the window already open.
REQUEST_BYTES=50000000
# Far more requests than a window can use, so a stream never runs dry.
REQUESTS_PER_STREAM=1000

# A base URL the probe appends its paths to: https, a host, an optional port
# and path, and nothing curl would read as a glob, a query or a fragment.
base_url_ok() {
  [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]
}

# Stream counts and durations in seconds.
small_int_ok() {
  [[ "$1" =~ ^[1-9][0-9]?$ ]]
}

# The LAN port has an IPv4 address and a default route. Anything else is a
# device that cannot reach the speed test endpoint.
uplink_ready() {
  ip -4 -o addr show dev "${NETWORK_INTERFACE}" 2>/dev/null | grep -qw inet \
    && ip -4 route show default dev "${NETWORK_INTERFACE}" 2>/dev/null | grep -q '^default'
}

# lan_bytes rx|tx
# The LAN port's byte counter in that direction.
lan_bytes() {
  local counter="${GVPN_NET_CLASS:-/sys/class/net}/${NETWORK_INTERFACE}/statistics/$1_bytes" value
  { read -r value < "${counter}"; } 2>/dev/null || return 1
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  echo "${value}"
}

# stream down|up [PAYLOAD]
# One stream of back-to-back requests on one reused connection. It replaces
# the calling subshell, so the PID the caller holds is curl's own.
# --fail-early ends the stream on the first rejected request and --speed-limit
# on a stall, so a stream that stops transferring also stops running.
stream() {
  local args=(-sS --fail --fail-early --proto "=https" --connect-timeout 10 --speed-limit 1 --speed-time 5)
  case "$1" in
    down)
      exec curl "${args[@]}" \
        "${GVPN_CAPACITY_URL}/__down?bytes=${REQUEST_BYTES}&n=[1-${REQUESTS_PER_STREAM}]" >/dev/null ;;
    up)
      exec curl "${args[@]}" -H 'Expect:' -X POST -T "$2" \
        "${GVPN_CAPACITY_URL}/__up?n=[1-${REQUESTS_PER_STREAM}]" >/dev/null ;;
  esac
}

# phase_kbit down|up [PAYLOAD]
# The LAN port's rate in that direction over the window, in kbit/s, while
# GVPN_CAPACITY_STREAMS streams keep it busy. The bytes include every other
# flow on the port, which is the link's traffic too.
phase_kbit() {
  local direction="$1" counter=rx pids=() pid i start end rc ended=0
  [[ "${direction}" == up ]] && counter=tx
  for ((i = 0; i < GVPN_CAPACITY_STREAMS; i++)); do
    stream "${direction}" "${2:-}" &
    pids+=("$!")
  done
  sleep "${GVPN_CAPACITY_WARMUP_S}"
  start="$(lan_bytes "${counter}")" || start=""
  sleep "${GVPN_CAPACITY_WINDOW_S}"
  end="$(lan_bytes "${counter}")" || end=""
  # A stream stopped here ends on SIGTERM (143). Any other exit happened inside
  # the window, a rejected request, a stall or a dropped connection, and left
  # part of it idle, so the rate would understate the link.
  kill "${pids[@]}" 2>/dev/null || true
  for pid in "${pids[@]}"; do
    rc=0
    wait "${pid}" 2>/dev/null || rc=$?
    (( rc == 143 )) || ended=1
  done
  if (( ended )); then
    log "${direction}load: a stream ended before the window closed"
    return 1
  fi
  if [[ -z "${start}" || -z "${end}" ]]; then
    log "${direction}load: cannot read the ${counter}_bytes counter of ${NETWORK_INTERFACE}"
    return 1
  fi
  echo $(( (end - start) * 8 / 1000 / GVPN_CAPACITY_WINDOW_S ))
}

# Run the probe and print "<down_kbit> <up_kbit> <latency_ms> <endpoint>"; the
# endpoint is the host, followed by Cloudflare's data centre when it names one.
measure() {
  local knob headers min_rtt_us latency=unknown colo down up payload endpoint
  if ! base_url_ok "${GVPN_CAPACITY_URL}"; then
    log "GVPN_CAPACITY_URL=${GVPN_CAPACITY_URL} is not an https base URL"
    return 1
  fi
  for knob in GVPN_CAPACITY_STREAMS GVPN_CAPACITY_WARMUP_S GVPN_CAPACITY_WINDOW_S; do
    if ! small_int_ok "${!knob}"; then
      log "${knob}=${!knob} is not a number from 1 to 99"
      return 1
    fi
  done
  if ! kbit_ok "${GVPN_CAPACITY_MIN_KBIT}"; then
    log "GVPN_CAPACITY_MIN_KBIT=${GVPN_CAPACITY_MIN_KBIT} is not a rate in kbit/s"
    return 1
  fi
  # One empty request first: an endpoint that cannot be reached fails here,
  # before any stream loads the link. Cloudflare's answer names the data centre
  # in CF-RAY and reports its own TCP statistics in Server-Timing; min_rtt (in
  # microseconds) is the latency without queueing. Other endpoints send
  # neither, and the log then names only the host.
  headers="$(curl -sS --fail --proto "=https" --max-time 10 -o /dev/null -D - \
    "${GVPN_CAPACITY_URL}/__down?bytes=0" | tr -d '\r')" || return 1
  min_rtt_us="$(sed -n 's/^server-timing:.*cfL4;.*[?&]min_rtt=\([0-9]\{1,9\}\)[&"].*/\1/Ip' <<< "${headers}" | head -n 1)"
  [[ -z "${min_rtt_us}" ]] || latency="$(awk -v us="${min_rtt_us}" 'BEGIN { printf "%.1f\n", us / 1000 }')"
  colo="$(sed -n 's/^cf-ray: *[0-9a-f]*-\([A-Z]\{3,4\}\)$/\1/Ip' <<< "${headers}" | head -n 1)"
  down="$(phase_kbit down)" || return 1
  # Sparse: the upload body reads as zeros and takes no space in the private /tmp.
  payload="$(mktemp)"
  truncate -s "${REQUEST_BYTES}" "${payload}"
  up="$(phase_kbit up "${payload}")" || up=""
  rm -f "${payload}"
  kbit_ok "${down}" && kbit_ok "${up}" || return 1
  # The streams ran to the end of the window, but on a link throttled to a
  # trickle: not the link the device normally has, so not a sample to shape to.
  if ! capacity_sample_ok "${down}" "${up}"; then
    log "measured down=${down}kbit up=${up}kbit is below GVPN_CAPACITY_MIN_KBIT=${GVPN_CAPACITY_MIN_KBIT}"
    return 1
  fi
  endpoint="${GVPN_CAPACITY_URL#https://}"
  endpoint="${endpoint%%/*}"
  printf '%s %s %s %s\n' "${down}" "${up}" "${latency}" "${endpoint}${colo:+ ${colo}}"
}

iso_now() {
  date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ
}

# write_cache DOWN_KBIT UP_KBIT MEASURED_AT ATTEMPT ATTEMPT_AT
# The sample stays empty until a probe succeeds; an attempt always records its
# own outcome, so the diagnostics can tell "measured" from "assumed".
write_cache() {
  {
    echo "# Uplink sample written by capacity.sh; do not edit."
    echo "GVPN_CAPACITY_SCHEMA=${GVPN_CAPACITY_SCHEMA}"
    echo "GVPN_CAPACITY_DOWN_KBIT=$1"
    echo "GVPN_CAPACITY_UP_KBIT=$2"
    echo "GVPN_CAPACITY_MEASURED_AT=$3"
    echo "GVPN_CAPACITY_ATTEMPT=$4"
    echo "GVPN_CAPACITY_ATTEMPT_AT=$5"
  } | write_atomic "$(capacity_file)"
}

main() {
  local now down up sample server latency via
  now="$(iso_now)"
  # The last good sample survives a failed probe.
  down="${GVPN_CAPACITY_DOWN_KBIT}"
  up="${GVPN_CAPACITY_UP_KBIT}"

  # A pinned aggregate is what the device shapes to, so the sample would not be
  # used for anything but the diagnostics, which keep the last one.
  if [[ "${GVPN_CAPACITY_SOURCE}" == pinned ]]; then
    log "the peer aggregate is pinned in ${GVPN_EXIT_OVERRIDES}; skipping the capacity probe"
    write_cache "${down}" "${up}" "${GVPN_CAPACITY_MEASURED_AT}" skipped "${now}"
    return 0
  fi

  if ! uplink_ready; then
    log "no usable uplink on ${NETWORK_INTERFACE}; skipping the capacity probe"
    write_cache "${down}" "${up}" "${GVPN_CAPACITY_MEASURED_AT}" skipped "${now}"
    return 0
  fi

  if sample="$(measure)"; then
    read -r down up latency server <<< "${sample}"
    write_cache "${down}" "${up}" "${now}" ok "${now}"
    # Re-read the env so the log line reports what this sample actually yields;
    # the `auto` knobs are restored by the image defaults.
    load_exit_env
    via="via ${server}"
    [[ "${latency}" == unknown ]] || via+=" (${latency} ms)"
    log "uplink measured down=${down}kbit up=${up}kbit ${via}; peer aggregate ${GVPN_PEER_SHAPING_AGGREGATE_KBIT}kbit, ${GVPN_PEER_COUNT} slot(s)"
    return 0
  fi

  write_cache "${down}" "${up}" "${GVPN_CAPACITY_MEASURED_AT}" failed "${now}"
  if [[ -n "${GVPN_CAPACITY_MEASURED_AT}" ]]; then
    log "capacity probe failed; keeping the sample from ${GVPN_CAPACITY_MEASURED_AT}"
  else
    log "capacity probe failed; no sample yet, the supported-environment fallback applies"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
