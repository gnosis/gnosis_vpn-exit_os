#!/usr/bin/env bats
# Address discovery through the service entry point and operator CLI.

load helpers

setup() {
  setup_sandbox
  provision_sandbox
  CLI="${ROOTFS}/usr/bin/gvpn-exit-hoprd-address"
  ADDRESS="${GVPN_STATE_DIR}/hoprd-host.env"
  printf 'GVPN_PUBLIC_IP_URLS="https://ip-a.example https://ip-b.example"\n' > "${GVPN_EXIT_OVERRIDES}"
  mock_cmd curl 'echo 8.8.4.4'
  mock_cmd systemctl
  export GVPN_SELF_IPSET_BIN="${MOCK_BIN}/self-ipset"
  mock_cmd self-ipset
}

teardown() {
  teardown_sandbox
}

@test "initial discovery saves address and enables announcement without restarting hoprd" {
  run bash "${CLI}" init
  [ "${status}" -eq 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1' ]
  [ "$(stat -c %a "${ADDRESS}")" = 644 ]
  [[ "$(calls)" != *systemctl* ]]
}

@test "refreshes the self-address ipset after saving an announced address" {
  run bash "${CLI}" init

  [ "${status}" -eq 0 ]
  grep -qx 'self-ipset ' "${MOCK_LOG}"
}

# The device override in /etc/gvpn-exit/exit.env is the documented way to
# change the discovery services; this entry point has to read it too.
@test "honours GVPN_PUBLIC_IP_URLS from the device overrides" {
  printf 'GVPN_PUBLIC_IP_URLS="https://only.example/probe"\n' > "${GVPN_EXIT_OVERRIDES}"

  run bash "${CLI}" init

  [ "${status}" -eq 0 ]
  grep -qx 'curl -4 -fsS --max-time 10 https://only.example/probe' "${MOCK_LOG}"
  [ "$(grep -c '^curl ' "${MOCK_LOG}")" -eq 1 ]
}

# The address is saved before the address set refresh; a failed refresh leaves
# stale entries in the firewall until the next netprobe run, but it must not
# stop the activation.
@test "a failed self-address ipset refresh does not block activation" {
  printf 'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1\n' > "${ADDRESS}"
  mock_cmd self-ipset 'exit 1'

  run bash "${CLI}" refresh

  [ "${status}" -eq 0 ]
  grep -qx 'systemctl restart hoprd.service' "${MOCK_LOG}"
  [[ "${output}" == *"failed to refresh the self-address ipset"* ]]
}

@test "successful initialization survives subsequent starts without probing or rewriting" {
  printf 'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1\n' > "${ADDRESS}"
  run bash "${CLI}" init
  [ "${status}" -eq 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1' ]
  [ ! -s "${MOCK_LOG}" ]
}

@test "offline initial attempt permits boot and retries until one succeeds" {
  mock_cmd curl 'exit 6'
  run bash "${CLI}" init
  [ "${status}" -eq 0 ]
  [ ! -e "${ADDRESS}" ]
  [[ "${output}" == *"unannounced"* ]]
  mock_cmd curl 'echo 8.8.4.4'
  run bash "${CLI}" init
  [ "${status}" -eq 0 ]
  [ -s "${ADDRESS}" ]
}

@test "refresh saves the new address and activates it even if unchanged" {
  printf 'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1\n' > "${ADDRESS}"
  run bash "${CLI}" refresh
  [ "${status}" -eq 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1' ]
  [[ "$(calls)" == *"systemctl restart hoprd.service"* ]]
  : > "${MOCK_LOG}"
  run bash "${CLI}" refresh
  [ "${status}" -eq 0 ]
  [[ "$(calls)" == *"systemctl restart hoprd.service"* ]]
}

@test "failed or nonpublic discovery preserves configuration and does not restart" {
  printf 'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1\n' > "${ADDRESS}"
  for answer in '<html>error</html>' 192.168.1.10 100.64.0.0 100.127.255.255 \
      172.16.0.0 172.31.255.255 127.0.0.1 0.0.0.0 224.0.0.1 198.51.100.1 8.8.4.999; do
    mock_cmd curl "printf '%s\n' '${answer}'"
    run bash "${CLI}" refresh
    [ "${status}" -ne 0 ]
    [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1' ]
    [[ "$(calls)" != *systemctl* ]]
  done
  mock_cmd curl 'exit 6'
  run bash "${CLI}" refresh
  [ "${status}" -ne 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1' ]
  [[ "$(calls)" != *systemctl* ]]
}

@test "public addresses immediately outside CGNAT and private ranges are accepted" {
  for answer in 100.63.255.255 100.128.0.0 172.15.255.255 172.32.0.0; do
    mock_cmd curl "echo '${answer}'"
    run bash "${CLI}" refresh
    [ "${status}" -eq 0 ]
    [ "$(cat "${ADDRESS}")" = "$(printf 'HOPRD_HOST=%s:9091\nHOPRD_ANNOUNCE=1' "${answer}")" ]
  done
}

@test "discovery falls back after an unavailable echo service" {
  mock_cmd curl '[[ "$*" == *ip-a.example* ]] && exit 6; echo 8.8.4.4'
  run bash "${CLI}" refresh
  [ "${status}" -eq 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1' ]
}

@test "default discovery falls back to Cloudflare and extracts only the ip field" {
  rm -f "${GVPN_EXIT_OVERRIDES}"
  mock_cmd curl '[[ "${*: -1}" == https://www.cloudflare.com/cdn-cgi/trace ]] || exit 6
    printf "fl=123\nh=www.cloudflare.com\nip=8.8.4.4\ncolo=FRA\nwarp=off\n"'
  run bash "${CLI}" refresh
  [ "${status}" -eq 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1' ]
}

@test "invalid Cloudflare trace preserves the previous address without restarting" {
  printf 'GVPN_PUBLIC_IP_URLS=https://www.cloudflare.com/cdn-cgi/trace\n' > "${GVPN_EXIT_OVERRIDES}"
  printf 'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1\n' > "${ADDRESS}"
  for trace in 'colo=FRA' 'ip=192.168.1.10' 'ip=2001:db8::1' 'ip=not-an-ip'; do
    mock_cmd curl "printf '%s\n' '${trace}'"
    run bash "${CLI}" refresh
    [ "${status}" -ne 0 ]
    [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1' ]
    [[ "$(calls)" != *systemctl* ]]
  done
}

@test "discovery skips a private echo answer and uses the public fallback" {
  mock_cmd curl 'if [[ "$*" == *ip-a.example* ]]; then echo 192.168.1.10; else echo 8.8.4.4; fi'
  run bash "${CLI}" refresh
  [ "${status}" -eq 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=8.8.4.4:9091\nHOPRD_ANNOUNCE=1' ]
}

@test "write failure preserves previous address and does not restart" {
  printf 'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1\n' > "${ADDRESS}"
  mock_cmd mv 'exit 1'
  run bash "${CLI}" refresh
  [ "${status}" -ne 0 ]
  [ "$(cat "${ADDRESS}")" = $'HOPRD_HOST=9.9.9.9:9091\nHOPRD_ANNOUNCE=1' ]
  [[ "$(calls)" != *systemctl* ]]
}

@test "activation releases the discovery lock before starting dependent services" {
  mock_cmd systemctl 'exec 9>"${GVPN_RUN_DIR}/hoprd-address.lock"; flock -w 1 9'
  run bash "${CLI}" refresh
  [ "${status}" -eq 0 ]
  [ -s "${ADDRESS}" ]
}

@test "restart failure reports saved configuration but failed activation" {
  mock_cmd systemctl 'exit 1'
  run bash "${CLI}" refresh
  [ "${status}" -ne 0 ]
  [ -s "${ADDRESS}" ]
  [[ "${output}" == *"saved"*"activation failed"* ]]
}

@test "unprovisioned device rejects initialization and refresh without side effects" {
  rm "${GVPN_IDENTITY_DIR}/provisioned"
  for command in init refresh; do
    run bash "${CLI}" "${command}"
    [ "${status}" -ne 0 ]
    [ ! -e "${ADDRESS}" ]
    [ ! -s "${MOCK_LOG}" ]
  done
}

@test "unknown command returns usage without network access" {
  run bash "${CLI}" bogus
  [ "${status}" -eq 64 ]
  [ ! -s "${MOCK_LOG}" ]
}
