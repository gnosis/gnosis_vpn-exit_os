#!/usr/bin/env bats
# The image defaults remain unannounced until discovery provides a public IP.
# The image build validates both configurations with the pinned hoprd-cfg.

load helpers

CFG="${SHARE}/hoprd.cfg.yaml"

@test "hoprd defaults to unannounced until initialization succeeds" {
  [[ "$(cat "${CFG}")" == *$'\n  announce: false'* ]]
}

@test "image defaults do not hardcode a public address" {
  [[ "$(cat "${SHARE}/hoprd.env" "${SHARE}/exit.env")" != *$'\nHOPRD_HOST='* ]]
}

@test "integration provisioning requires an explicit Blokli endpoint" {
  setup_sandbox
  mock_cmd ssh 'exit 1'
  mock_cmd sleep 'exit 1'
  run env -u VM_BLOKLI_URL bash "${REPO_ROOT}/tests/integration/run.sh" provision
  teardown_sandbox
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"VM_BLOKLI_URL"* ]]
}

@test "the session allow list matches the client's built-in session targets" {
  # The GnosisVPN client defaults its bridge and WireGuard targets to
  # 172.30.0.1; hoprd must forward exactly there.
  grep -q '"172.30.0.1:8000"' "${CFG}"
  grep -q '"172.30.0.1:51820"' "${CFG}"
}

@test "v5 configuration carries PIX and its admission rules" {
  grep -q '^    - Pix:$' "${CFG}"
  grep -q '^  session_admission_rules:$' "${CFG}"
  grep -q 'enforce_pix: true' "${CFG}"
  grep -q 'relayer_url: https://api.curvy.box' "${CFG}"
  grep -q 'state_path: /var/lib/hoprd-v5/curvy-pix.redb' "${CFG}"
  grep -q '^  network:$' "${CFG}"
}

@test "v5 configuration no longer carries the v4-only channel knobs" {
  ! grep -q 'min_safe_capacity_required' "${CFG}"
  ! grep -q 'stop_when_unfunded' "${CFG}"
}

@test "v5 keeps its database and identity off the v4 paths" {
  grep -qx 'HOPRD_DATA=/var/lib/hoprd-v5' "${SHARE}/hoprd.env"
  grep -qx 'CURVY_ZK_KEYS_DIR=/usr/share/gvpn-exit/curvy-zk' "${SHARE}/hoprd.env"
  [ -f "${SHARE}/hoprd-v4.cfg.yaml" ]
  [ "$(awk '/^blokli_url:/ {print $2}' "${SHARE}/hoprd-v4.cfg.yaml")" = "https://blokli.example.org" ]
}

@test "the v4 cleanup configuration cannot reopen channels" {
  ! grep -q 'ChannelLifecycle' "${SHARE}/hoprd-v4.cfg.yaml"
  grep -q 'AutoRedeeming' "${SHARE}/hoprd-v4.cfg.yaml"
}

@test "the v5 log filter matches the deployment baseline" {
  grep -qx 'RUST_LOG=info,isahc=error,sea_orm=warn,sqlx=warn,hyper_util=warn,hickory_resolver=warn' "${SHARE}/hoprd.env"
}
