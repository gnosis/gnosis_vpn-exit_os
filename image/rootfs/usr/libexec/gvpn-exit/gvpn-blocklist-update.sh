#!/usr/bin/env bash
# Every knob comes from exit.env.
#
# Populates the GVPN_BLOCKLIST_IPSET_NAME ipset used by the FORWARD DROP rules
# that wg-hooks.sh installs. Two modes:
#   --from-cache  load the local cache file only (no network). Used at boot,
#                 ordered before gnosisvpn-server, so the set is populated before
#                 the wggvpn interface starts forwarding.
#   --refresh     fetch the threat feeds, refresh the cache, swap into the set.
#                 Used by the twice-daily timer.
#
# Populating the live set always goes through an atomic `ipset swap`, so in-flight
# packets never see a partially-built set. The set is fail-open: any degraded path
# keeps the existing set (or an empty one) and the script still exits 0, surfacing
# problems through Prometheus metrics rather than failing the unit.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

IPSET_NAME="${GVPN_BLOCKLIST_IPSET_NAME}"
IPSET_STAGING="${IPSET_NAME}-staging-$$"
IPSET_MAXELEM="${GVPN_BLOCKLIST_MAXELEM}"
CACHE_DIR="${GVPN_BLOCKLIST_CACHE_DIR}"
CACHE_FILE="${CACHE_DIR}/blocklist.cidr"
TEXTFILE_DIR="${GVPN_BLOCKLIST_TEXTFILE_DIR}"
METRIC_FILE="${TEXTFILE_DIR}/gvpn-blocklist.prom"
MIN_ENTRIES="${GVPN_BLOCKLIST_MIN_ENTRIES}"
CURL_TIMEOUT="${GVPN_BLOCKLIST_CURL_TIMEOUT}"
# Hard cap on each feed's download size. Bounds disk/memory use if a feed is
# compromised or misbehaving and streams an unexpectedly large body.
MAX_FILESIZE="${GVPN_BLOCKLIST_MAX_FILESIZE}"
# Share of the IPv4 space the list may drop. The entry count alone does not
# catch a poisoned feed: a few thousand /8s pass every count check and cut off
# almost every session. The default FireHOL level1 snapshot covers roughly 14%
# of IPv4 (it aggregates whole networks), so this is a ceiling against a
# catastrophic list, not a policy about what a feed may contain.
MAX_COVERAGE_PCT="${GVPN_BLOCKLIST_MAX_COVERAGE_PCT:-25}"

read -r -a FEEDS <<< "${GVPN_BLOCKLIST_FEEDS}"

TMP_DIR=""
RESTORE_FILE=""

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

cleanup() {
  [[ -n "${RESTORE_FILE}" ]] && rm -f "${RESTORE_FILE}"
  [[ -n "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
  ipset destroy "${IPSET_STAGING}" 2>/dev/null || true
}
trap cleanup EXIT

# Strip comments (; and #), drop whitespace, keep only valid IPv4 / IPv4-CIDR
# tokens (bare IPs are valid hash:net members, treated as /32).
#
# IPv4-only by design: the live set is `family inet` and this parser rejects any
# non-IPv4 token. This is safe only while IPv6 egress stays disabled on exit
# nodes (no net.ipv6.conf.*.forwarding, no IPv6 addresses, ip6tables FORWARD DROP). If IPv6
# forwarding is ever enabled, blocked destinations become reachable over IPv6 and
# an ip6tables guard / family inet6 set must be added.
#
# The octet (0-255) and prefix (/0../32) sub-patterns are validated here so that
# ipset never sees an out-of-range token that would abort the whole restore.
# Prefixes shorter than /8 are accepted only for the statically dropped 224/3
# bogon range: a single 0.0.0.0/1 or 128.0.0.0/1 would send every VPN session
# into the blocklist DROP while the entry-count checks stay green.
parse_feed() {
  sed -e 's/[;#].*$//' -e 's/[[:space:]]//g' \
    | grep -E '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(/(3[0-2]|[12][0-9]|[0-9]))?$' \
    | awk -F '[./]' 'NF == 4 || $5 >= 8 || $1 >= 224' || true
}

# covered_addresses FILE
# IPv4 addresses the list would drop, as a plain integer. Saturating is not
# needed: awk's doubles are exact far beyond 2^32.
covered_addresses() {
  awk -F'[./]' '
    NF > 0 { p = (NF == 5 ? $5 : 32); covered += 2 ^ (32 - p) }
    END { printf "%.0f\n", covered }' "$1"
}

# A list that would drop more than MAX_COVERAGE_PCT of the IPv4 space is
# treated as poisoned, like an out-of-band entry count: the existing set stays.
coverage_within_bounds() {
  local file="$1" covered limit
  covered="$(covered_addresses "${file}")" || return 1
  limit=$(( MAX_COVERAGE_PCT * 42949673 ))
  if (( covered > limit )); then
    log "ERROR the list would drop ${covered} addresses, more than ${MAX_COVERAGE_PCT}% of IPv4; keeping existing set"
    return 1
  fi
  return 0
}

# Whether a parsed entry count is within the acceptable [MIN_ENTRIES, IPSET_MAXELEM]
# range. A count outside this band is treated as a degraded/broken list and the
# caller keeps the existing set instead of swapping (fail-safe).
count_within_bounds() {
  local count="$1"
  if [[ "${count}" -lt "${MIN_ENTRIES}" ]]; then
    log "ERROR ${count} entries (< ${MIN_ENTRIES}); keeping existing set"
    return 1
  fi
  if [[ "${count}" -gt "${IPSET_MAXELEM}" ]]; then
    log "ERROR ${count} entries (> maxelem ${IPSET_MAXELEM}); keeping existing set"
    return 1
  fi
  return 0
}

# Ensure the live set exists so the iptables DROP rules always resolve, even when
# we have nothing to populate it with.
ensure_live_set() {
  ipset create "${IPSET_NAME}" hash:net family inet maxelem "${IPSET_MAXELEM}" -exist
}

# Build and validate the staging set from $1. This is intentionally separated
# from cache publication so malformed feed/cache data never becomes the new
# known-good cache.
stage_set() {
  local src="$1"
  ipset destroy "${IPSET_STAGING}" 2>/dev/null || true
  RESTORE_FILE=$(mktemp) || return 1
  {
    echo "create ${IPSET_STAGING} hash:net family inet maxelem ${IPSET_MAXELEM}"
    sed "s|^|add ${IPSET_STAGING} |" "${src}"
  } > "${RESTORE_FILE}" || return 1
  # -exist makes the adds idempotent: a duplicate CIDR (e.g. a bare IP from one
  # feed colliding with the same X/32 from another) no longer aborts the whole
  # restore.
  ipset restore -exist < "${RESTORE_FILE}" || return 1
  rm -f "${RESTORE_FILE}"
  RESTORE_FILE=""
}

# Atomically replace the live set's contents with the already-validated CIDRs in
# $1.
swap_in() {
  local src="$1"
  stage_set "${src}" || return 1
  ensure_live_set || return 1
  ipset swap "${IPSET_STAGING}" "${IPSET_NAME}" || return 1
  ipset destroy "${IPSET_STAGING}" 2>/dev/null || true
}

publish_cache() {
  local src="$1"
  mkdir -p "${CACHE_DIR}" || return 1
  cp "${src}" "${CACHE_FILE}.tmp" || return 1
  mv "${CACHE_FILE}.tmp" "${CACHE_FILE}" || return 1
}

# entries fetch_failed -> textfile metrics. The timestamp is the cache file mtime,
# i.e. the last time feeds were successfully fetched.
#
# The metrics are for the dashboard, never for the load: this script is the
# required gvpn-blocklist-boot.service, so a full or unwritable textfile
# directory costs the metrics and nothing else.
write_metrics() {
  if ! write_metrics_file "$@"; then
    log "WARN cannot write ${METRIC_FILE}; the blocklist stays loaded without metrics"
  fi
}

write_metrics_file() {
  local entries="$1" failed="$2" ts=0 tmp="${METRIC_FILE}.tmp"
  if [[ -f "${CACHE_FILE}" ]]; then
    ts=$(stat -c %Y "${CACHE_FILE}") || return 1
  fi
  mkdir -p "${TEXTFILE_DIR}" || return 1
  # Chained, because write_metrics calls this in a condition, where errexit is
  # off: a write that stops part-way (a full filesystem) must not be published
  # over the previous file, so it is removed and the caller told.
  if ! cat > "${tmp}" <<EOF
# HELP gvpn_blocklist_entries Number of CIDR entries currently in the blocklist ipset.
# TYPE gvpn_blocklist_entries gauge
gvpn_blocklist_entries ${entries}
# HELP gvpn_blocklist_last_success_timestamp_seconds Unix time of the last successful feed fetch (cache mtime).
# TYPE gvpn_blocklist_last_success_timestamp_seconds gauge
gvpn_blocklist_last_success_timestamp_seconds ${ts}
# HELP gvpn_blocklist_fetch_failed Whether the most recent feed fetch failed (1) or not (0).
# TYPE gvpn_blocklist_fetch_failed gauge
gvpn_blocklist_fetch_failed ${failed}
EOF
  then
    rm -f "${tmp}"
    return 1
  fi
  mv "${tmp}" "${METRIC_FILE}"
}

# Emit metrics reflecting the live set's current contents (used when we keep the
# existing set instead of swapping).
emit_current() {
  local failed="${1:-0}" count=0
  if ! ensure_live_set; then
    log "ERROR failed to ensure live ipset; writing zero-entry failure metrics"
    write_metrics 0 1
    return 0
  fi
  if ! count=$(ipset list "${IPSET_NAME}" 2>/dev/null | awk '/Number of entries/{print $4}'); then
    log "ERROR failed to inspect live ipset; writing zero-entry failure metrics"
    write_metrics 0 1
    return 0
  fi
  write_metrics "${count:-0}" "${failed}"
}

populate_from_cache() {
  local failed="${1:-0}" count
  if [[ ! -s "${CACHE_FILE}" ]]; then
    log "ERROR cache file ${CACHE_FILE} missing or empty; leaving set empty"
    emit_current 1
    return 0
  fi
  count=$(wc -l < "${CACHE_FILE}")
  if ! count_within_bounds "${count}"; then
    emit_current 1
    return 0
  fi
  if ! coverage_within_bounds "${CACHE_FILE}"; then
    emit_current 1
    return 0
  fi
  if ! swap_in "${CACHE_FILE}"; then
    log "ERROR cache failed ipset validation; keeping existing set"
    emit_current 1
    return 0
  fi
  write_metrics "${count}" "${failed}"
  log "populated from cache: ${count} entries"
}

refresh() {
  local all feed_failed=0 feed_success=0 count
  TMP_DIR=$(mktemp -d)
  all="${TMP_DIR}/all.cidr"
  : > "${all}"
  for url in "${FEEDS[@]}"; do
    # The feed URL is https, but a redirect is not bound by that: without the
    # proto pins a mirror could send the fetch to plain http, where anyone on
    # the path chooses the blocklist.
    if curl -fsSL --proto =https --proto-redir =https \
      --max-time "${CURL_TIMEOUT}" --max-filesize "${MAX_FILESIZE}" \
      --retry 3 --retry-delay 5 "${url}" > "${TMP_DIR}/feed"; then
      parse_feed < "${TMP_DIR}/feed" >> "${all}"
      feed_success=$((feed_success + 1))
      log "fetched ${url}"
    else
      feed_failed=1
      log "WARN failed to fetch ${url}"
    fi
  done

  if [[ "${feed_success}" -eq 0 ]]; then
    log "ERROR all feeds failed; falling back to cache"
    populate_from_cache 1
    return 0
  fi
  if [[ "${feed_failed}" -ne 0 ]]; then
    log "ERROR one or more feeds failed; keeping existing set and cache"
    emit_current 1
    return 0
  fi

  sort -u "${all}" -o "${all}"
  count=$(wc -l < "${all}")
  if ! count_within_bounds "${count}"; then
    emit_current 1
    return 0
  fi
  if ! coverage_within_bounds "${all}"; then
    emit_current 1
    return 0
  fi

  if ! swap_in "${all}"; then
    log "ERROR parsed CIDR list failed ipset validation; keeping existing set and cache"
    emit_current 1
    return 0
  fi
  if ! publish_cache "${all}"; then
    log "ERROR failed to update cache after live swap"
    emit_current 1
    return 0
  fi
  write_metrics "${count}" 0
  log "refresh complete: ${count} entries"
}

# Only dispatch when executed directly, not when sourced (e.g. by the bats unit
# tests, which exercise parse_feed / count_within_bounds in isolation).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --from-cache) populate_from_cache 0 ;;
    --refresh)    refresh ;;
    *)
      echo "usage: $0 --from-cache|--refresh" >&2
      exit 2
      ;;
  esac
fi
