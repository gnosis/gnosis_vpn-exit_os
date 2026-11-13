#!/usr/bin/env bash
# gvpn-exit-heartbeat.service (every 15 min) and greenboot green.d/red.d.
#
# POSTs the device state to the fleet backend (GVPN_FLEET_URL from
# /etc/gvpn-exit/fleet.env, written at provisioning): identity, image, boot
# verdict, live service health, the network report netprobe keeps in
# state/reachability.json, the announced public address with its drift from the
# observed one, and the rejected digests. The response body is ignored, but an
# HTTP error fails the unit, so the journal shows it; alerting on silent
# devices is the backend's job (outside this repository). A payload that
# cannot be built fails the unit instead of sending an empty body.
#
# The body is signed with the TPM-sealed support key: the same key the bastion
# authorizes and whose public half the provisioning record carries. The
# signature is an SSH signature over the canonical payload without its
# `signature` member, so the backend can reproduce the bytes:
#
#   jq -cS 'del(.signature)' | ssh-keygen -Y verify -n gvpn-exit-heartbeat \
#     -f <allowed_signers> -I <device_id> -s <signature>
#
# A device without a usable key sends `signature: null`; how to treat that is
# the backend's decision.
#
#   heartbeat.sh [--status green|red]
# Without --status the boot health is derived from boot-complete.target,
# which greenboot only lets the boot reach when all required checks pass.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"
load_exit_env

GVPN_FLEET_ENV="${GVPN_FLEET_ENV:-/etc/gvpn-exit/fleet.env}"
GVPN_HOPRD_HOST_ENV="${GVPN_HOPRD_HOST_ENV:-${GVPN_STATE_DIR}/hoprd-host.env}"
REACHABILITY_FILE="${GVPN_REACHABILITY_FILE:-${GVPN_STATE_DIR}/reachability.json}"
SUPPORT_UNTIL="${GVPN_STATE_DIR}/support-until"
BLOCKLIST_CACHE_FILE="${GVPN_BLOCKLIST_CACHE_FILE:-${GVPN_BLOCKLIST_CACHE_DIR}/blocklist.cidr}"
HOPRD_HEALTH_URL="${HOPRD_HEALTH_URL:-http://127.0.0.1:3001/healthyz}"
HEARTBEAT_NAMESPACE=gvpn-exit-heartbeat
WORK=""

cleanup() {
  if [[ -n "${WORK}" ]]; then
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

greenboot_status() {
  if systemctl is-active boot-complete.target >/dev/null 2>&1; then
    echo green
  else
    echo red
  fi
}

# The advertised address, without the port.
announced_ip() {
  if [[ -s "${GVPN_HOPRD_HOST_ENV}" ]]; then
    sed -n 's/^HOPRD_HOST=\([^:]*\).*/\1/p' "${GVPN_HOPRD_HOST_ENV}"
  fi
}

observed_ip() {
  if [[ -s "${REACHABILITY_FILE}" ]]; then
    jq -r '.public_ip // empty' "${REACHABILITY_FILE}" 2>/dev/null || true
  fi
}

service_state() {
  systemctl is-active "$1" 2>/dev/null || true
}

api_answers() {
  curl -fsS --max-time 5 -o /dev/null "$1" 2>/dev/null
}

# Age of the blocklist cache, i.e. of the last successful feed fetch.
blocklist_age_s() {
  local mtime age
  if [[ -s "${BLOCKLIST_CACHE_FILE}" ]]; then
    mtime="$(stat -c %Y "${BLOCKLIST_CACHE_FILE}")"
    age=$(( $(now_epoch) - mtime ))
    (( age < 0 )) && age=0
    echo "${age}"
  fi
}

local_value() {
  if [[ -s "$1" ]]; then
    cat "$1"
  fi
}

health_json() {
  local hoprd vpn_server api blocklist staged support_until
  hoprd="$(service_state hoprd.service)"
  vpn_server="$(service_state gnosisvpn-server.service)"
  api=false
  api_answers "${HOPRD_HEALTH_URL}" && api=true
  blocklist="$(blocklist_age_s)"
  staged="$(staged_image_digest || true)"
  support_until="$(local_value "${SUPPORT_UNTIL}")"
  jq -n \
    --arg hoprd "${hoprd:-unknown}" \
    --arg vpn_server "${vpn_server:-unknown}" \
    --argjson hoprd_api "${api}" \
    --argjson blocklist_age "${blocklist:-null}" \
    --arg staged "${staged}" \
    --arg support_until "${support_until}" \
    '{
      hoprd: $hoprd,
      hoprd_api: $hoprd_api,
      vpn_server: $vpn_server,
      blocklist_age_s: $blocklist_age,
      staged_digest: ($staged | select(. != "") // null),
      support_until: ($support_until | select(. != "") // null)
    }'
}

# The uplink sample (capacity.sh) and the capacity lib.sh derived from it, so a
# device that runs on the supported-environment floor or on a stale sample is
# visible in the fleet without reading its journal.
capacity_json() {
  jq -n \
    --arg source "${GVPN_CAPACITY_SOURCE}" \
    --arg measured_at "${GVPN_CAPACITY_MEASURED_AT}" \
    --arg down "${GVPN_CAPACITY_DOWN_KBIT}" \
    --arg up "${GVPN_CAPACITY_UP_KBIT}" \
    --arg attempt "${GVPN_CAPACITY_ATTEMPT}" \
    --arg attempt_at "${GVPN_CAPACITY_ATTEMPT_AT}" \
    --arg aggregate "${GVPN_PEER_SHAPING_AGGREGATE_KBIT}" \
    --arg ceiling "${GVPN_PEER_CEIL_KBIT}" \
    --arg guarantee "${GVPN_PEER_GUARANTEE_KBIT}" \
    --arg slots "${GVPN_PEER_COUNT}" \
    'def num: if . == "" then null else (try tonumber catch null) end;
    {
      source: $source,
      measured_down_kbit: ($down | num),
      measured_up_kbit: ($up | num),
      measured_at: ($measured_at | select(. != "") // null),
      last_attempt: ($attempt | select(. != "") // null),
      last_attempt_at: ($attempt_at | select(. != "") // null),
      aggregate_kbit: ($aggregate | num),
      peer_ceiling_kbit: ($ceiling | num),
      peer_guarantee_kbit: ($guarantee | num),
      peer_slots: ($slots | num)
    }'
}

build_payload() {
  local status="$1" booted reachability='{}' rejected='[]' announced observed drift=false
  booted="$(bootc_status_json | jq -c '.status.booted.image // {}')"
  if [[ -s "${REACHABILITY_FILE}" ]]; then
    reachability="$(< "${REACHABILITY_FILE}")"
  fi
  if [[ -s "${GVPN_STATE_DIR}/rejected-digests" ]]; then
    rejected="$(jq -R . "${GVPN_STATE_DIR}/rejected-digests" | jq -sc .)"
  fi
  announced="$(announced_ip || true)"
  observed="$(observed_ip || true)"
  if [[ -n "${announced}" && -n "${observed}" && "${announced}" != "${observed}" ]]; then
    drift=true
  fi
  jq -n \
    --arg device_id "$(cat "${GVPN_IDENTITY_DIR}/serial" 2>/dev/null || echo unknown)" \
    --argjson booted "${booted}" \
    --arg greenboot_status "${status}" \
    --arg hoprd_version "$(hoprd --version 2>/dev/null | head -1 || true)" \
    --arg announced "${announced}" \
    --argjson drift "${drift}" \
    --argjson health "$(health_json)" \
    --argjson capacity "$(capacity_json)" \
    --argjson reachability "${reachability}" \
    --argjson rejected "${rejected}" \
    --arg sent_at "$(date -u -d "@$(now_epoch)" +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      device_id: $device_id,
      image: ($booted.image.image // null),
      image_digest: ($booted.imageDigest // null),
      image_version: ($booted.version // null),
      greenboot_status: $greenboot_status,
      hoprd_version: $hoprd_version,
      announced_ip: ($announced | select(. != "") // null),
      address_drift: $drift,
      health: $health,
      capacity: $capacity,
      reachability: $reachability,
      rejected_digests: $rejected,
      sent_at: $sent_at,
      signature: null
    }'
}

# Set SIGNING_KEY to the private half of the support key, if this context has
# one: an explicit override (tests, manual runs), the unit's credential
# directory, or the sealed credential decrypted here, because the greenboot
# hooks run this script directly, without a credential directory. It sets WORK
# (the script's private temporary directory) instead of printing the path, so
# the EXIT trap removes the decrypted key.
signing_key() {
  local cred_file="${GVPN_CREDS_DIR}/support.key.cred"
  SIGNING_KEY=""
  if [[ -n "${GVPN_HEARTBEAT_KEY:-}" ]]; then
    if [[ -s "${GVPN_HEARTBEAT_KEY}" ]]; then
      SIGNING_KEY="${GVPN_HEARTBEAT_KEY}"
    fi
    return 0
  fi
  if [[ -s "${CREDENTIALS_DIRECTORY:-/nonexistent}/support.key" ]]; then
    SIGNING_KEY="${CREDENTIALS_DIRECTORY}/support.key"
    return 0
  fi
  if [[ -s "${cred_file}" ]] && command -v systemd-creds >/dev/null; then
    work_dir
    if systemd-creds decrypt --name=support.key "${cred_file}" "${WORK}/support.key" 2>/dev/null; then
      SIGNING_KEY="${WORK}/support.key"
    fi
  fi
  return 0
}

# The private working directory, created once so the EXIT trap sees it.
work_dir() {
  if [[ -z "${WORK}" ]]; then
    WORK="$(mktemp -d)"
    chmod 0700 "${WORK}"
  fi
}

# Sign the canonical payload (compact, sorted keys, without `signature`) and
# put namespace, public key and armored signature into the body. A signing
# failure is logged and the heartbeat goes out unsigned: a silent device is
# worse than one the backend can see.
add_signature() {
  local body="$1" key="${SIGNING_KEY}"
  if [[ -z "${key}" ]]; then
    log "no support key available; sending the heartbeat unsigned"
    echo "${body}"
    return 0
  fi
  work_dir
  if ! jq -cS 'del(.signature)' <<< "${body}" > "${WORK}/canonical.json" \
      || ! ssh-keygen -Y sign -q -f "${key}" -n "${HEARTBEAT_NAMESPACE}" "${WORK}/canonical.json" >/dev/null; then
    log "WARNING signing the heartbeat failed; sending it unsigned"
    echo "${body}"
    return 0
  fi
  jq -c \
    --arg namespace "${HEARTBEAT_NAMESPACE}" \
    --arg key "$(ssh-keygen -y -f "${key}")" \
    --rawfile sig "${WORK}/canonical.json.sig" \
    '.signature = {namespace: $namespace, key: $key, sig: $sig}' <<< "${body}"
}

# The target URL from fleet.env. Parsed, never sourced: another script writes
# that file, and a value there must not run as root.
fleet_url() {
  sed -n 's/^GVPN_FLEET_URL=//p' "${GVPN_FLEET_ENV}" | tail -1
}

main() {
  local status="" payload body url
  if [[ "${1:-}" == "--status" ]]; then
    status="${2:?--status needs green or red}"
  fi
  if [[ ! -f "${GVPN_FLEET_ENV}" ]]; then
    log "no fleet endpoint configured (${GVPN_FLEET_ENV})"
    return 1
  fi
  url="$(fleet_url)"
  if [[ -z "${url}" ]]; then
    log "ERROR GVPN_FLEET_URL missing in ${GVPN_FLEET_ENV}"
    return 1
  fi
  if ! https_url_ok "${url}"; then
    log "ERROR GVPN_FLEET_URL in ${GVPN_FLEET_ENV} is not a usable https URL; not sending"
    return 1
  fi

  # Captured separately: a failing payload build must fail the unit, not send
  # an empty body that looks like a successful heartbeat.
  if ! payload="$(build_payload "${status:-$(greenboot_status)}")" || [[ -z "${payload}" ]]; then
    log "ERROR could not build the heartbeat payload"
    return 1
  fi
  signing_key
  body="$(add_signature "${payload}")"
  if [[ -z "${body}" ]]; then
    log "ERROR the heartbeat body is empty; not sending"
    return 1
  fi
  if ! printf '%s\n' "${body}" \
      | curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @- "${url}" >/dev/null; then
    log "ERROR the fleet endpoint at ${url} did not accept the heartbeat"
    return 1
  fi
  log "heartbeat sent"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
