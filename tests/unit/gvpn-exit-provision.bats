#!/usr/bin/env bats
# gvpn-exit-provision: provisioning in two steps.
#   identity  create node identity + secrets and seal them to the TPM
#   finalize  write the Safe/network config, record data ownership and the
#             provisioning record, then the `provisioned` marker last

load helpers

NODE_ADDRESS="0x1234567890abcdef1234567890abcdef12345678"
SAFE="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
MODULE="0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

setup() {
  setup_sandbox
  export GVPN_NOW=1790220600
  export GVPN_ETC_DIR="${SANDBOX}/etc"
  export GVPN_EXIT_OVERRIDES="${GVPN_ETC_DIR}/exit.env"
  export GVPN_HOPRD_ENV_DIR="${SANDBOX}/etc/hoprd.env.d"
  export GVPN_HOPRD_CFG_TEMPLATE="${SHARE}/hoprd.cfg.yaml"
  export GVPN_DMI_SERIAL="${SANDBOX}/product_serial"
  export GVPN_WORK_PARENT="${SANDBOX}/run"
  export GVPN_MACHINE_ID="${SANDBOX}/machine-id"
  echo "0123456789abcdef0123456789abcdef" > "${GVPN_MACHINE_ID}"
  echo "SER8-0001" > "${GVPN_DMI_SERIAL}"
  CLI="${ROOTFS}/usr/bin/gvpn-exit-provision"

  mock_cmd systemd-analyze '[[ "$1" == has-tpm2 ]]'
  mock_cmd systemd-creds '
case "$1" in
  encrypt) in="${@: -2:1}"; out="${@: -1}"; { echo SEALED; cat "$in"; } > "$out" ;;
esac'
  mock_cmd hopli "
case \"\$2\" in
  create) dir=\"\$(sed -n 's/.*--identity-directory \\([^ ]*\\).*/\\1/p' <<< \"\$*\")\"; echo keystore > \"\${dir}/hopr0.id\" ;;
  read) echo 'Identity addresses: [${NODE_ADDRESS}]'; echo 'Identity peerids: [12D3KooWPeer]' ;;
esac"
  mock_cmd wg '
case "$1" in
  genkey) echo "aGVsbG8gd29ybGQgdGhpcyBpcyAzMiBieXRlcyBrZXk=" ;;
  pubkey) echo "cHVibGljIGtleSBvZiB0aGUgd2lyZWd1YXJkIHNlcnY=" ;;
esac'
  mock_cmd ssh-keygen 'f="$(sed -n "s/.*-f \([^ ]*\).*/\1/p" <<< "$*")"; echo PRIVATE > "$f"; echo "ssh-ed25519 AAAA support" > "$f.pub"'
  mock_cmd bootc 'echo "{\"status\":{\"booted\":{\"image\":{\"imageDigest\":\"sha256:cur\"}}}}"'
  mock_cmd systemctl
  mock_cmd timedatectl 'echo yes'
  mock_cmd sync
}

teardown() {
  teardown_sandbox
}

finalize() {
  "${CLI}" finalize --safe-address "${SAFE}" --module-address "${MODULE}" \
    --blokli-url https://blokli-test.example.org --location "Berlin, DE" "$@"
}

# Every file under the directories finalize writes to, with a checksum: a
# refused finalize has to leave all of them as they were.
tree_state() {
  local dir file
  for dir in "${GVPN_ETC_DIR}" "${GVPN_HOPRD_ENV_DIR}"; do
    [[ -d "${dir}" ]] || continue
    find "${dir}" -type f | sort | while IFS= read -r file; do
      printf '%s %s\n' "${file}" "$(cksum < "${file}")"
    done
  done
}

@test "identity seals every secret into the creds directory" {
  run "${CLI}" identity
  [ "${status}" -eq 0 ]
  for id in hopr.id hoprd.password hoprd.api-token wg.key support.key; do
    [ "$(head -1 "${GVPN_CREDS_DIR}/${id}.cred")" = "SEALED" ]
  done
}

@test "identity names the bastion steps only on a device the installer gave a bastion" {
  run "${CLI}" identity
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"add the support key to the bastion"* ]]
  [[ "${output}" != *"enrollment key"* ]]
  [[ "${output}" == *"no support bastion is configured"* ]]
  [[ "${output}" == *"gvpn-exit-provision finalize"* ]]
}

@test "identity binds credentials to the TPM without PCR policy" {
  run "${CLI}" identity
  grep -q 'systemd-creds encrypt --with-key=tpm2 --tpm2-device=auto --tpm2-pcrs= --name=hoprd.password' "${MOCK_LOG}"
}

@test "identity never leaves plaintext secrets behind" {
  run "${CLI}" identity
  [ -z "$(ls -A "${GVPN_WORK_PARENT}")" ]
  ! grep -rq 'PRIVATE' "${GVPN_IDENTITY_DIR}" "${GVPN_STATE_DIR}"
}

@test "identity uses the same random password to create and read the keystore" {
  mock_cmd hopli "echo \"PW=\${IDENTITY_PASSWORD}\" >> \"${SANDBOX}/pw.log\"
case \"\$2\" in
  create) dir=\"\$(sed -n 's/.*--identity-directory \\([^ ]*\\).*/\\1/p' <<< \"\$*\")\"; echo keystore > \"\${dir}/hopr0.id\" ;;
  read) echo 'Identity addresses: [${NODE_ADDRESS}]'; echo 'Identity peerids: [12D3KooWPeer]' ;;
esac"
  run "${CLI}" identity
  [ "$(sort -u "${SANDBOX}/pw.log" | wc -l)" -eq 1 ]
  [[ "$(cat "${SANDBOX}/pw.log" | head -1)" =~ ^PW=[0-9a-f]{64}$ ]]
}

@test "identity records the public identity and prints what the operator needs" {
  run "${CLI}" identity
  [ "$(jq -r .node_address "${GVPN_IDENTITY_DIR}/node.json")" = "${NODE_ADDRESS}" ]
  [ "$(jq -r .peer_id "${GVPN_IDENTITY_DIR}/node.json")" = "12D3KooWPeer" ]
  [ "$(jq -r .wg_public_key "${GVPN_IDENTITY_DIR}/node.json")" = "cHVibGljIGtleSBvZiB0aGUgd2lyZWd1YXJkIHNlcnY=" ]
  [ "$(jq -r .support_public_key "${GVPN_IDENTITY_DIR}/node.json")" = "ssh-ed25519 AAAA support" ]
  [ "$(cat "${GVPN_IDENTITY_DIR}/serial")" = "SER8-0001" ]
  [[ "${output}" == *"${NODE_ADDRESS}"* ]]
}

@test "identity falls back to the machine id when the firmware has no serial" {
  : > "${GVPN_DMI_SERIAL}"
  run "${CLI}" identity
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_IDENTITY_DIR}/serial")" = "0123456789abcdef0123456789abcdef" ]
}

@test "identity reads the node address from the addresses line, not from key logs" {
  # hopli logs the packet public key on stdout before the addresses line
  mock_cmd hopli "
case \"\$2\" in
  create) dir=\"\$(sed -n 's/.*--identity-directory \\([^ ]*\\).*/\\1/p' <<< \"\$*\")\"; echo keystore > \"\${dir}/hopr0.id\" ;;
  read) echo 'INFO hopli_lib::identity: Identities: {\"x\": HoprKeys { packet_key: (priv_key: <REDACTED>, pub_key: 0x1eeb0789bcf57e41c819beb40fd5a92c588f5e00d2e6065e4aded80cb21dc485 }}'
        echo 'Identity addresses: [${NODE_ADDRESS}]'; echo 'Identity peerids: [12D3KooWPeer]' ;;
esac"
  run "${CLI}" identity
  [ "${status}" -eq 0 ]
  [ "$(jq -r .node_address "${GVPN_IDENTITY_DIR}/node.json")" = "${NODE_ADDRESS}" ]
}

@test "identity refuses to overwrite an existing identity" {
  run "${CLI}" identity
  run "${CLI}" identity
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already"* ]]
}

@test "identity refuses without a TPM" {
  mock_cmd systemd-analyze 'exit 1'
  run "${CLI}" identity
  [ "${status}" -ne 0 ]
  [ ! -e "${GVPN_CREDS_DIR}/hopr.id.cred" ]
}

@test "finalize requires the identity step first" {
  run finalize
  [ "${status}" -ne 0 ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

@test "finalize writes the hoprd network configuration" {
  "${CLI}" identity
  run finalize
  [ "${status}" -eq 0 ]
  env="${GVPN_HOPRD_ENV_DIR}/10-provisioned.env"
  grep -qx "HOPRD_SAFE_ADDRESS=${SAFE}" "${env}"
  grep -qx "HOPRD_MODULE_ADDRESS=${MODULE}" "${env}"
  grep -qx "HOPRD_BLOKLI_URL=https://blokli-test.example.org" "${env}"
}

@test "finalize rejects malformed addresses and URLs" {
  "${CLI}" identity
  run "${CLI}" finalize --safe-address 0x123 --module-address "${MODULE}" --blokli-url https://b.example --location X
  [ "${status}" -ne 0 ]
  run "${CLI}" finalize --safe-address "${SAFE}" --module-address "${MODULE}" --blokli-url ftp://b.example --location X
  [ "${status}" -ne 0 ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

# Both URLs land in files that another script reads as a value, so only a
# plain https URL may through: no whitespace, quotes, backslashes, `$(` or
# backticks, which would otherwise be executed or break the consumer.
@test "finalize rejects URLs carrying shell metacharacters" {
  "${CLI}" identity
  for url in 'https://b.example/x?y=$(id)' 'https://b.example/x?y=`id`' \
      'https://b.example/x y' 'https://b.example/"x"' 'https://b.example/x/{y}'; do
    run "${CLI}" finalize --safe-address "${SAFE}" --module-address "${MODULE}" --blokli-url "${url}" --location X
    [ "${status}" -ne 0 ] || { echo "accepted ${url}"; false; }
    run "${CLI}" finalize --safe-address "${SAFE}" --module-address "${MODULE}" \
      --blokli-url https://blokli-test.example.org --location X --fleet-url "${url}"
    [ "${status}" -ne 0 ] || { echo "accepted fleet ${url}"; false; }
  done
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
  [ ! -e "${GVPN_ETC_DIR}/fleet.env" ]
}

@test "finalize refuses a bastion that is not user@host" {
  "${CLI}" identity
  run finalize --support-port 22001 --bastion 'support@bastion.example
evil'
  [ "${status}" -ne 0 ]
  [ ! -e "${SUPPORT_ENV:-${GVPN_ETC_DIR}/support.env}" ]
}

@test "finalize refuses to run twice on a provisioned device" {
  "${CLI}" identity
  run finalize
  [ "${status}" -eq 0 ]
  record="$(cat "${GVPN_IDENTITY_DIR}/provisioning.json")"
  echo 2026-01-01T00:00:00Z > "${GVPN_IDENTITY_DIR}/provisioned"
  run finalize --support-days 5
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already provisioned"* ]]
  [ "$(cat "${GVPN_IDENTITY_DIR}/provisioning.json")" = "${record}" ]
}

@test "finalize records the booted deployment as data owner" {
  "${CLI}" identity
  run finalize
  [ "$(cat "${GVPN_STATE_DIR}/data-owner")" = "sha256:cur" ]
}

@test "finalize writes the provisioning record with the exit metadata" {
  "${CLI}" identity
  run finalize --support-port 22001 --bastion support@bastion.example
  record="${GVPN_IDENTITY_DIR}/provisioning.json"
  [ "$(jq -r .node_address "${record}")" = "${NODE_ADDRESS}" ]
  [ "$(jq -r .safe_address "${record}")" = "${SAFE}" ]
  [ "$(jq -r .serial "${record}")" = "SER8-0001" ]
  [ "$(jq -r .support_port "${record}")" = "22001" ]
  [ "$(jq -r .exit.gnosis_vpn_server "${record}")" = "172.30.0.1:8000" ]
  [ "$(jq -r .exit.wireguard_server "${record}")" = "172.30.0.1:51820" ]
  [ "$(jq -r .exit.location "${record}")" = "Berlin, DE" ]
}

@test "finalize applies device shaping overrides" {
  "${CLI}" identity
  run finalize --peer-rate-kbit 5000 --aggregate-kbit 12000 --peer-max-octet 4
  grep -qx 'GVPN_PEER_RATE_KBIT=5000' "${GVPN_EXIT_OVERRIDES}"
  grep -qx 'GVPN_PEER_SHAPING_AGGREGATE_KBIT=12000' "${GVPN_EXIT_OVERRIDES}"
  grep -qx 'GVPN_PEER_MAX_OCTET=4' "${GVPN_EXIT_OVERRIDES}"
}

@test "finalize configures the support tunnel and opens its window" {
  "${CLI}" identity
  run finalize --support-port 22001 --bastion support@bastion.example --support-days 30
  grep -qx 'SUPPORT_PORT=22001' "${GVPN_ETC_DIR}/support.env"
  grep -qx 'BASTION=support@bastion.example' "${GVPN_ETC_DIR}/support.env"
  [ "$(cat "${GVPN_STATE_DIR}/support-until")" = "2026-10-24T03:30:00Z" ]
}

# What the installer's kickstart %post writes for the enrollment tunnel.
installer_support_env() {
  printf 'SUPPORT_PORT=22001\nBASTION=support@bastion.example\n' > "${GVPN_ETC_DIR}/support.env"
  echo PRIVATE > "${GVPN_ETC_DIR}/enroll.key"
}

@test "finalize keeps the bastion the installer configured" {
  installer_support_env
  "${CLI}" identity
  run finalize --support-days 7
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_ETC_DIR}/support.env")" = "$(printf 'SUPPORT_PORT=22001\nBASTION=support@bastion.example')" ]
  [ "$(jq -r .support_port "${GVPN_IDENTITY_DIR}/provisioning.json")" = "22001" ]
}

@test "finalize flags override the installer's support port and bastion one by one" {
  installer_support_env
  "${CLI}" identity
  run finalize --support-port 22002 --support-days 7
  [ "${status}" -eq 0 ]
  grep -qx 'SUPPORT_PORT=22002' "${GVPN_ETC_DIR}/support.env"
  grep -qx 'BASTION=support@bastion.example' "${GVPN_ETC_DIR}/support.env"
}

@test "finalize refuses a support port without a bastion" {
  "${CLI}" identity
  run finalize --support-port 22001
  [ "${status}" -ne 0 ]
  [ ! -e "${GVPN_ETC_DIR}/support.env" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

@test "finalize opens a default support window when a bastion is configured" {
  installer_support_env
  "${CLI}" identity
  run finalize
  [ "${status}" -eq 0 ]
  grep -q 'systemctl start support-tunnel.service' "${MOCK_LOG}"
  [ "$(cat "${GVPN_STATE_DIR}/support-until")" = "2026-12-23T03:30:00Z" ]
}

@test "finalize opens no window without a bastion" {
  "${CLI}" identity
  run finalize
  [ "${status}" -eq 0 ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

# The window is opened by `gvpn-exit-support extend`, which runs after the
# network config, the shaping overrides, support.env and fleet.env are written.
# A window that cannot be opened has to cost nothing, so its length and the
# clock are checked before the first write.
@test "finalize refuses a support window longer than the maximum before writing anything" {
  "${CLI}" identity
  before="$(tree_state)"
  run finalize --support-days 120
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--support-days must be an integer between 1 and 90"* ]]
  [ "$(tree_state)" = "${before}" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

@test "finalize refuses a support window with a leading zero before writing anything" {
  "${CLI}" identity
  before="$(tree_state)"
  run finalize --support-days 08
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--support-days must be an integer between 1 and 90"* ]]
  [ "$(tree_state)" = "${before}" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

# A window is a deadline computed from the clock, so opening one on a device
# that has not synchronized yet would set it from whatever the RTC says.
@test "finalize refuses a support window while the clock is not NTP-synchronized" {
  installer_support_env
  "${CLI}" identity
  mock_cmd timedatectl 'echo no'
  before="$(tree_state)"
  run finalize
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not NTP-synchronized"* ]]
  [ "$(tree_state)" = "${before}" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
  grep -qx 'SUPPORT_PORT=22001' "${GVPN_ETC_DIR}/support.env"
}

@test "finalize needs no synchronized clock on a device without a bastion" {
  "${CLI}" identity
  mock_cmd timedatectl 'echo no'
  run finalize
  [ "${status}" -eq 0 ]
  [ -e "${GVPN_IDENTITY_DIR}/provisioned" ]
  [ ! -e "${GVPN_STATE_DIR}/support-until" ]
}

@test "finalize removes the enrollment key once the device is provisioned" {
  installer_support_env
  "${CLI}" identity
  run finalize --support-days 7
  [ "${status}" -eq 0 ]
  [ -e "${GVPN_IDENTITY_DIR}/provisioned" ]
  [ ! -e "${GVPN_ETC_DIR}/enroll.key" ]
}

@test "a failed finalize keeps the enrollment key so the tunnel still works" {
  installer_support_env
  "${CLI}" identity
  run finalize --safe-address 0xnope
  [ "${status}" -ne 0 ]
  [ -e "${GVPN_ETC_DIR}/enroll.key" ]
}

@test "identity asks for the support key on the bastion before finalize" {
  mkdir -p "${GVPN_ETC_DIR}"
  printf 'SUPPORT_PORT=22001\nBASTION=support@bastion.example\n' > "${GVPN_ETC_DIR}/support.env"
  run "${CLI}" identity
  [[ "${output}" != *"no support bastion is configured"* ]]
  [[ "${output}" == *"add the support key to the bastion"* ]]
  [[ "${output}" == *"enrollment key"* ]]
}

@test "finalize configures the fleet heartbeat endpoint" {
  "${CLI}" identity
  run finalize --fleet-url https://fleet.example/v1/heartbeat
  grep -qx 'GVPN_FLEET_URL=https://fleet.example/v1/heartbeat' "${GVPN_ETC_DIR}/fleet.env"
}

@test "finalize writes the provisioned marker last" {
  "${CLI}" identity
  run finalize
  [ "${status}" -eq 0 ]
  newest="$(ls -t "${GVPN_IDENTITY_DIR}"/* "${GVPN_STATE_DIR}"/* "${GVPN_HOPRD_ENV_DIR}"/* | head -1)"
  [ "${newest}" = "${GVPN_IDENTITY_DIR}/provisioned" ]
  grep -q '^sync' "${MOCK_LOG}"
}

@test "status reports an unprovisioned device" {
  run "${CLI}" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"unprovisioned"* ]]
}

@test "identity can be retried after sealing a credential failed" {
  mock_cmd systemd-creds '
[[ "$*" == *--name=hoprd.password* ]] && { echo "TPM error" >&2; exit 1; }
case "$1" in
  encrypt) in="${@: -2:1}"; out="${@: -1}"; { echo SEALED; cat "$in"; } > "$out" ;;
esac'
  run "${CLI}" identity
  [ "${status}" -ne 0 ]
  [ -z "$(ls -A "${GVPN_CREDS_DIR}")" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/node.json" ]
  mock_cmd systemd-creds '
case "$1" in
  encrypt) in="${@: -2:1}"; out="${@: -1}"; { echo SEALED; cat "$in"; } > "$out" ;;
esac'
  run "${CLI}" identity
  [ "${status}" -eq 0 ]
  for id in hopr.id hoprd.password hoprd.api-token wg.key support.key; do
    [ "$(head -1 "${GVPN_CREDS_DIR}/${id}.cred")" = "SEALED" ]
  done
}

@test "identity publishes the sealed identity, nothing else, in the creds directory" {
  run "${CLI}" identity
  [ "${status}" -eq 0 ]
  [ "$(LC_ALL=C ls -A "${GVPN_CREDS_DIR}" | xargs)" = "hopr.id.cred hoprd.api-token.cred hoprd.password.cred support.key.cred wg.key.cred" ]
}

@test "finalize refuses a peer pool the WireGuard renderer would reject" {
  "${CLI}" identity
  for max in 255 1 0255 04 1000; do
    run finalize --peer-max-octet "${max}"
    [ "${status}" -ne 0 ] || { echo "accepted --peer-max-octet ${max}"; false; }
    [[ "${output}" == *"--peer-max-octet"* ]]
  done
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
  ! grep -q 'GVPN_PEER_MAX_OCTET' "${GVPN_EXIT_OVERRIDES}" 2>/dev/null
}

@test "finalize accepts the widest pool the renderer accepts" {
  "${CLI}" identity
  run finalize --peer-max-octet 254
  [ "${status}" -eq 0 ]
  grep -qx 'GVPN_PEER_MAX_OCTET=254' "${GVPN_EXIT_OVERRIDES}"
}

# With an aggregate pin and GVPN_PEER_MAX_OCTET=auto the boot derives the pool
# from the pinned aggregate, so a small aggregate serves one client. The check
# has to evaluate the same way: the pool of a cached measurement would leave that
# aggregate without a per-peer share and refuse what the boot accepts.
@test "finalize evaluates a pinned aggregate with the pool the boot derives" {
  "${CLI}" identity
  seed_capacity 200000 200000
  run finalize --aggregate-kbit 5
  [ "${status}" -eq 0 ]
  grep -qx 'GVPN_PEER_SHAPING_AGGREGATE_KBIT=5' "${GVPN_EXIT_OVERRIDES}"
  [ -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

# The runtime accepts a rate only as kbit_ok: no zero, no leading zero. finalize
# runs once and writes a file that survives a rollback, so a value the shaping
# unit would reject has to be refused here.
@test "finalize refuses shaping rates the runtime rejects and writes nothing" {
  "${CLI}" identity
  for bad in 0 010000; do
    run finalize --peer-rate-kbit "${bad}"
    [ "${status}" -ne 0 ] || { echo "accepted --peer-rate-kbit ${bad}"; false; }
    [[ "${output}" == *"--peer-rate-kbit"* ]]
    run finalize --aggregate-kbit "${bad}"
    [ "${status}" -ne 0 ] || { echo "accepted --aggregate-kbit ${bad}"; false; }
    [[ "${output}" == *"--aggregate-kbit"* ]]
  done
  [ ! -e "${GVPN_EXIT_OVERRIDES}" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

# An aggregate that cannot give every octet of the pool a share leaves the peer
# count empty, and the server would refuse to shape on every boot.
@test "finalize refuses an aggregate that cannot feed the pool and writes nothing" {
  "${CLI}" identity
  run finalize --aggregate-kbit 100 --peer-max-octet 254
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no per-peer share"* ]]
  [ ! -e "${GVPN_EXIT_OVERRIDES}" ]
  [ ! -e "${GVPN_IDENTITY_DIR}/provisioned" ]
}

@test "identity treats a firmware placeholder serial like a missing one" {
  local placeholder
  for placeholder in "Default string" "To be filled by O.E.M." "System Serial Number" \
      "Not Specified" "0000000000" "None" "N/A" "Unknown" "Chassis Serial Number"; do
    rm -rf "${GVPN_CREDS_DIR}" "${GVPN_IDENTITY_DIR}"
    mkdir -p "${GVPN_CREDS_DIR}" "${GVPN_IDENTITY_DIR}"
    printf '%s\n' "${placeholder}" > "${GVPN_DMI_SERIAL}"

    run "${CLI}" identity

    [ "${status}" -eq 0 ] || { echo "refused '${placeholder}': ${output}"; false; }
    [ "$(cat "${GVPN_IDENTITY_DIR}/serial")" = "0123456789abcdef0123456789abcdef" ] \
      || { echo "'${placeholder}' became a device id"; false; }
  done
}

@test "finalize says where the node address has to be before clients use the exit" {
  "${CLI}" identity
  run finalize
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keep it"* ]]
  [[ "${output}" == *"destination list"* ]]
  [[ "${output}" == *"docs/first-install.md"* ]]
}
