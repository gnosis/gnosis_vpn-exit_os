#!/usr/bin/env bats
# heartbeat.sh reports device state to the fleet backend. The device never
# stores anything the backend answers: hoprd is outbound-only, so there is no
# inbound reachability verdict to keep.

load helpers

setup() {
  setup_sandbox
  export GVPN_NOW=1790220600
  export GVPN_FLEET_ENV="${SANDBOX}/etc/fleet.env"
  echo "GVPN_FLEET_URL=https://fleet.example/v1/heartbeat" > "${GVPN_FLEET_ENV}"
  echo "SER8-0001" > "${GVPN_IDENTITY_DIR}/serial"
  echo '{"public_ip":"203.0.113.7","nat":"ok","cgnat":false}' > "${GVPN_STATE_DIR}/reachability.json"
  mock_cmd bootc 'echo "{\"status\":{\"booted\":{\"image\":{\"image\":{\"image\":\"registry.example/gvpn-exit-os:stable\"},\"imageDigest\":\"sha256:cur\",\"version\":\"1.2.3\"}}}}"'
  mock_cmd hoprd 'echo "hoprd 5.0.2"'
  mock_cmd systemctl 'echo active'
  # curl mock: the health probe answers, the heartbeat keeps the request body
  mock_cmd curl '
last="${*: -1}"
case "${last}" in
  *healthyz) exit 0 ;;
  *fleet.example/v1/heartbeat) cat > "'"${SANDBOX}"'/payload.json" ;;
  *) exit 7 ;;
esac'
  }

teardown() {
  teardown_sandbox
}

payload() {
  jq -r "$1" "${SANDBOX}/payload.json"
}

@test "posts the device state to the configured endpoint" {
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -eq 0 ]
  grep -q 'curl .*https://fleet.example/v1/heartbeat' "${MOCK_LOG}"
  [ "$(payload .device_id)" = "SER8-0001" ]
  [ "$(payload .image_digest)" = "sha256:cur" ]
  [ "$(payload .image_version)" = "1.2.3" ]
  [ "$(payload .hoprd_version)" = "hoprd 5.0.2" ]
  [ "$(payload .reachability.public_ip)" = "203.0.113.7" ]
  [ "$(payload .reachability.nat)" = "ok" ]
}

@test "reports the measured capacity and the peer pool derived from it" {
  seed_capacity 200000 120000
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -eq 0 ]
  [ "$(payload .capacity.source)" = "measured" ]
  [ "$(payload .capacity.measured_down_kbit)" = "200000" ]
  [ "$(payload .capacity.measured_up_kbit)" = "120000" ]
  [ "$(payload .capacity.measured_at)" = "2026-10-01T03:00:00Z" ]
  [ "$(payload .capacity.last_attempt)" = "ok" ]
  [ "$(payload .capacity.aggregate_kbit)" = "30000" ]
  [ "$(payload .capacity.peer_ceiling_kbit)" = "10000" ]
  [ "$(payload .capacity.peer_guarantee_kbit)" = "5000" ]
  [ "$(payload .capacity.peer_slots)" = "6" ]
}

@test "reports the supported-environment floor when nothing was measured" {
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -eq 0 ]
  [ "$(payload .capacity.source)" = "fallback" ]
  [ "$(payload .capacity.measured_down_kbit)" = "null" ]
  [ "$(payload .capacity.aggregate_kbit)" = "7500" ]
  [ "$(payload .capacity.peer_slots)" = "1" ]
}

@test "reports the NAT classification from a completed network probe" {
  printf 'GVPN_PUBLIC_IP_URLS=https://ip.example\n' > "${GVPN_EXIT_OVERRIDES}"
  mock_cmd ip 'echo "2: lan0 inet 192.168.1.50/24"'
  mock_cmd upnpc 'echo "ExternalIPAddress = 100.72.1.1"'
  mock_cmd curl "
    case \"\${*: -1}\" in
      https://ip.example) echo 203.0.113.7 ;;
      https://fleet.example/v1/heartbeat) cat > \"${SANDBOX}/payload.json\" ;;
      *) exit 1 ;;
    esac"
  run "${LIBEXEC}/netprobe.sh"
  [ "${status}" -eq 0 ]
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -eq 0 ]
  [ "$(payload .reachability.public_ip)" = "203.0.113.7" ]
  [ "$(payload .reachability.router_external_ip)" = "100.72.1.1" ]
  [ "$(payload .reachability.nat)" = "cgnat" ]
  [ "$(payload .reachability.cgnat)" = "true" ]
  [ "$(payload .reachability.checked_at)" = "2026-09-24T03:30:00Z" ]
}

@test "reports green when boot-complete.target was reached" {
  run "${LIBEXEC}/heartbeat.sh"
  [ "$(payload .greenboot_status)" = "green" ]
}

@test "reports red when the boot did not complete" {
  mock_cmd systemctl 'echo inactive; exit 3'
  run "${LIBEXEC}/heartbeat.sh"
  [ "$(payload .greenboot_status)" = "red" ]
}

@test "an explicit status argument wins" {
  run "${LIBEXEC}/heartbeat.sh" --status red
  [ "$(payload .greenboot_status)" = "red" ]
}

@test "includes the rejected digests" {
  printf 'sha256:bad\n' > "${GVPN_STATE_DIR}/rejected-digests"
  run "${LIBEXEC}/heartbeat.sh"
  [ "$(payload '.rejected_digests[0]')" = "sha256:bad" ]
}

@test "leaves reachability.json untouched whatever the backend answers" {
  before="$(cat "${GVPN_STATE_DIR}/reachability.json")"
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_STATE_DIR}/reachability.json")" = "${before}" ]
}

@test "fails when the backend cannot be reached" {
  mock_cmd curl 'exit 7'
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -ne 0 ]
}

@test "fails without a configured endpoint" {
  rm "${GVPN_FLEET_ENV}"
  run "${LIBEXEC}/heartbeat.sh"
  [ "${status}" -ne 0 ]
  ! grep -q '^curl' "${MOCK_LOG}"
}

# A payload that cannot be built must fail the unit: an empty body that the
# backend accepts looks like a healthy device.
@test "fails when the payload cannot be built, instead of sending an empty body" {
  mock_cmd bootc 'echo "bootc: cannot read the deployment" >&2; exit 1'

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not build the heartbeat payload"* ]]
  [ ! -e "${SANDBOX}/payload.json" ]
}

# fleet.env is read by a root process, so its value is parsed and validated as
# a URL: nothing in it may run.
@test "refuses a fleet URL that carries shell syntax, without sending" {
  echo 'GVPN_FLEET_URL=https://fleet.example/v1/heartbeat?x=$(touch '"${SANDBOX}"'/pwned)' > "${GVPN_FLEET_ENV}"

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -ne 0 ]
  [ ! -e "${SANDBOX}/pwned" ]
  ! grep -q 'fleet.example' "${MOCK_LOG}"
  [[ "${output}" == *"not a usable https URL"* ]]
}

@test "sends to a fleet URL with a query string as one argument" {
  echo 'GVPN_FLEET_URL=https://fleet.example/v1/heartbeat?device=1&key=2' > "${GVPN_FLEET_ENV}"
  mock_cmd curl '
last="${*: -1}"
case "${last}" in
  *healthyz) exit 0 ;;
  "https://fleet.example/v1/heartbeat?device=1&key=2") cat > "'"${SANDBOX}"'/payload.json" ;;
  *) exit 7 ;;
esac'

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -eq 0 ]
  [ "$(payload .device_id)" = "SER8-0001" ]
}

@test "removes the decrypted support key after the run" {
  mkdir -p "${SANDBOX}/tmp"
  export TMPDIR="${SANDBOX}/tmp"
  echo SEALED > "${GVPN_CREDS_DIR}/support.key.cred"
  mock_cmd systemd-creds 'out="${@: -1}"; echo PRIVATE > "${out}"'
  # No key given directly and no credential directory: the script decrypts the
  # sealed credential into its own temporary directory.
  unset GVPN_HEARTBEAT_KEY

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -eq 0 ]
  [ -z "$(ls -A "${SANDBOX}/tmp")" ]
}

@test "signs the canonical payload with the support key" {
  ssh-keygen -q -t ed25519 -N '' -C gvpn-exit-support-SER8-0001 -f "${SANDBOX}/support.key"
  export GVPN_HEARTBEAT_KEY="${SANDBOX}/support.key"

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -eq 0 ]
  [ "$(payload .signature.namespace)" = "gvpn-exit-heartbeat" ]
  [ "$(payload .signature.key)" = "$(ssh-keygen -y -f "${SANDBOX}/support.key")" ]
  # The backend verifies the payload without its signature member, serialized
  # with sorted keys, against the public half in the provisioning record.
  jq -cS 'del(.signature)' "${SANDBOX}/payload.json" > "${SANDBOX}/canonical.json"
  payload .signature.sig > "${SANDBOX}/payload.sig"
  printf 'device %s\n' "$(cut -d' ' -f1,2 < "${SANDBOX}/support.key.pub")" > "${SANDBOX}/allowed_signers"
  ssh-keygen -Y verify -f "${SANDBOX}/allowed_signers" -I device \
    -n gvpn-exit-heartbeat -s "${SANDBOX}/payload.sig" < "${SANDBOX}/canonical.json"
}

@test "sends the heartbeat unsigned when no support key is available" {
  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -eq 0 ]
  [ "$(payload .signature)" = "null" ]
}

@test "a broken signing key still lets the heartbeat through, unsigned" {
  printf 'not a key\n' > "${SANDBOX}/support.key"
  export GVPN_HEARTBEAT_KEY="${SANDBOX}/support.key"

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -eq 0 ]
  [ "$(payload .signature)" = "null" ]
  [[ "${output}" == *"signing the heartbeat failed"* ]]
}

@test "reports the announced address and its drift from the observed one" {
  printf 'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1\n' > "${GVPN_STATE_DIR}/hoprd-host.env"

  run "${LIBEXEC}/heartbeat.sh"

  [ "$(payload .announced_ip)" = "8.8.4.4" ]
  [ "$(payload .address_drift)" = "true" ]
}

@test "reports no drift while the announced address is the observed one" {
  printf 'HOPRD_HOST=203.0.113.7:9091\nHOPRD_ANNOUNCE=1\n' > "${GVPN_STATE_DIR}/hoprd-host.env"

  run "${LIBEXEC}/heartbeat.sh"

  [ "$(payload .announced_ip)" = "203.0.113.7" ]
  [ "$(payload .address_drift)" = "false" ]
}

@test "carries live health, the blocklist age and the support window" {
  echo 203.0.113.0/24 > "${SANDBOX}/blocklist.cidr"
  touch -d @1790220000 "${SANDBOX}/blocklist.cidr"
  printf '2026-10-01T00:00:00Z\n' > "${GVPN_STATE_DIR}/support-until"
  export GVPN_BLOCKLIST_CACHE_FILE="${SANDBOX}/blocklist.cidr"

  run "${LIBEXEC}/heartbeat.sh"

  [ "$(payload .health.hoprd)" = "active" ]
  [ "$(payload .health.hoprd_api)" = "true" ]
  [ "$(payload .health.vpn_server)" = "active" ]
  [ "$(payload .health.blocklist_age_s)" = "600" ]
  [ "$(payload .health.support_until)" = "2026-10-01T00:00:00Z" ]
}

@test "reports an unhealthy hoprd API without failing the heartbeat" {
  mock_cmd curl '
last="${*: -1}"
case "${last}" in
  *fleet.example/v1/heartbeat) cat > "'"${SANDBOX}"'/payload.json" ;;
  *) exit 7 ;;
esac'

  run "${LIBEXEC}/heartbeat.sh"

  [ "${status}" -eq 0 ]
  [ "$(payload .health.hoprd_api)" = "false" ]
}

@test "reports the staged deployment" {
  mock_cmd bootc 'echo "{\"status\":{\"booted\":{\"image\":{\"image\":{\"image\":\"registry.example/gvpn-exit-os:stable\"},\"imageDigest\":\"sha256:cur\",\"version\":\"1.2.3\"}},\"staged\":{\"image\":{\"imageDigest\":\"sha256:next\"}}}}"'

  run "${LIBEXEC}/heartbeat.sh"

  [ "$(payload .health.staged_digest)" = "sha256:next" ]
}
