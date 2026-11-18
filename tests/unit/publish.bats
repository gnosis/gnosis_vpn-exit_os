#!/usr/bin/env bats
# tools/publish.sh pushes the built image to the registry signed with the
# image-update key the devices trust, verifies the signature against the
# public half of that key and only then moves the channel tag the devices track.

load helpers

PUBLISH="${REPO_ROOT}/tools/publish.sh"
REPO="registry.example.org:5443/fleet/exit-os"
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
IMAGE_ID="2222222222222222222222222222222222222222222222222222222222222222"

setup() {
  setup_sandbox
  export GVPN_IMAGE_REPO="${REPO}"
  export GVPN_IMAGE_LAYOUT="${SANDBOX}/image"
  LAYOUT="oci:${GVPN_IMAGE_LAYOUT}:gvpn-exit-os"
  export GVPN_COSIGN_KEY="${SANDBOX}/cosign.key"
  echo "encrypted cosign key" > "${GVPN_COSIGN_KEY}"
  export GVPN_COSIGN_PUB="${SANDBOX}/cosign.pub"
  write_public_key "${GVPN_COSIGN_PUB}"
  # skopeo cannot ask for the passphrase on a run without a terminal.
  export GVPN_COSIGN_PASSPHRASE_FILE="${SANDBOX}/passphrase"
  : > "${GVPN_COSIGN_PASSPHRASE_FILE}"
  export GVPN_BUILDER="${MOCK_BIN}/builder"
  # builder mock: `podman image inspect` answers the ID of SOURCE_TAG.
  mock_cmd builder "echo ${IMAGE_ID}"
  layout_image "${IMAGE_ID}"
  image_version 1.2.3
  existing_version_tag no
  mock_cmd cosign
}

teardown() {
  teardown_sandbox
}

# The image the build's OCI layout holds, by its config digest without sha256:.
layout_image() {
  echo "$1" > "${SANDBOX}/layout-id"
}

# The version label of the image in the layout.
image_version() {
  echo "$1" > "${SANDBOX}/version"
  write_skopeo
}

existing_version_tag() {
  echo "$1" > "${SANDBOX}/version-exists"
  write_skopeo
}

# skopeo mock: inspect answers for the layout (its manifest with --raw, its
# labels without), the version tag (yes: exists, no: manifest unknown, anything
# else: a registry error) and the channel; copy --digestfile writes the pushed
# digest.
write_skopeo() {
  mock_cmd skopeo "
case \"\$*\" in
  *'inspect --raw oci:'*) echo \"{\\\"config\\\":{\\\"digest\\\":\\\"sha256:\$(cat '${SANDBOX}/layout-id')\\\"}}\" ;;
  *'inspect oci:'*) echo \"{\\\"Labels\\\":{\\\"org.opencontainers.image.version\\\":\\\"\$(cat '${SANDBOX}/version')\\\"}}\" ;;
  *'inspect'*':canary') echo '${DIGEST}' ;;
  *'inspect'*)
    case \"\$(cat '${SANDBOX}/version-exists')\" in
      yes) echo '${DIGEST}' ;;
      no) echo 'reading manifest 1.2.3 in ${REPO}: manifest unknown: Failed to fetch' >&2; exit 1 ;;
      *) echo 'received unexpected HTTP status: 503 Service Unavailable' >&2; exit 1 ;;
    esac ;;
  *'--digestfile'*) f=\"\$(sed -n 's/.*--digestfile \\([^ ]*\\).*/\\1/p' <<< \"\$*\")\"; echo -n '${DIGEST}' > \"\${f}\" ;;
esac"
}

@test "pushes the build's OCI layout as <repo>:<version>, signed the way the devices verify" {
  run "${PUBLISH}"
  [ "${status}" -eq 0 ]
  grep -qx 'builder podman image inspect --format {{.Id}} localhost/gvpn-exit-os:dev' "${MOCK_LOG}"
  grep -q "^skopeo copy .*--registries.d ${REPO_ROOT}/image/rootfs/etc/containers/registries.d " "${MOCK_LOG}"
  # The layout, not a copy out of the builder's storage, which would drop the
  # layer plan.
  grep -q "^skopeo copy .*--sign-by-sigstore-private-key ${GVPN_COSIGN_KEY} .*${LAYOUT} docker://${REPO}:1.2.3$" "${MOCK_LOG}"
  run grep -q 'podman save' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses a layout that does not hold the image SOURCE_TAG names" {
  layout_image 3333333333333333333333333333333333333333333333333333333333333333
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"localhost/gvpn-exit-os:dev"*"just build"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses to publish without the build's layout" {
  mock_cmd skopeo "case \"\$*\" in *'inspect --raw oci:'*) echo 'open index.json: no such file or directory' >&2; exit 1 ;; esac"
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${GVPN_IMAGE_LAYOUT}"*"just build"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "verifies the pushed digest against the update public key before moving the channel" {
  run "${PUBLISH}"
  [ "${status}" -eq 0 ]
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  verify_line="$(grep -n '^cosign verify' "${MOCK_LOG}" | cut -d: -f1)"
  move_line="$(grep -n ":canary$" "${MOCK_LOG}" | grep 'skopeo copy' | cut -d: -f1)"
  (( verify_line < move_line ))
}

@test "moves the channel to the pushed digest without rewriting it" {
  run "${PUBLISH}"
  grep -qx "skopeo copy --insecure-policy --preserve-digests --remove-signatures docker://${REPO}@${DIGEST} docker://${REPO}:canary" "${MOCK_LOG}"
}

@test "pushes the built image without moving a channel tag when --no-channel is passed" {
  run "${PUBLISH}" --no-channel
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no channel tag moved"* ]]
  grep -q "^skopeo copy .*--sign-by-sigstore-private-key ${GVPN_COSIGN_KEY} .*${LAYOUT} docker://${REPO}:1.2.3$" "${MOCK_LOG}"
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  run grep ':canary$' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "pushes the built image without moving a channel tag when push is passed" {
  run "${PUBLISH}" push
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no channel tag moved"* ]]
  grep -q "^skopeo copy .*--sign-by-sigstore-private-key ${GVPN_COSIGN_KEY} .*${LAYOUT} docker://${REPO}:1.2.3$" "${MOCK_LOG}"
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  run grep ':canary$' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "never moves the channel when the signature does not verify" {
  mock_cmd cosign 'exit 1'
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${GVPN_COSIGN_PUB}"* ]]
  run grep ':canary$' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses to overwrite a published version" {
  existing_version_tag yes
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"1.2.3"*"already published"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses an image without a usable version label" {
  for version in "" "1.2.3 bad" "-x"; do
    image_version "${version}"
    run "${PUBLISH}"
    [ "${status}" -ne 0 ] || { echo "accepted version '${version}'"; false; }
  done
}

@test "refuses the stable channel, which moves only by promotion" {
  run "${PUBLISH}" stable
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"promotion"* ]]
  [ ! -s "${MOCK_LOG}" ]
}

@test "refuses any channel tag other than canary" {
  for channel in 1.2.3 latest canary-2; do
    run "${PUBLISH}" "${channel}"
    [ "${status}" -ne 0 ] || { echo "moved ${channel}"; false; }
    [[ "${output}" == *"canary only"* ]]
    [ ! -s "${MOCK_LOG}" ]
  done
}

@test "refuses a version built from uncommitted source" {
  image_version "1.2.3-dirty"
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"uncommitted"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses to start without the update public key" {
  rm "${GVPN_COSIGN_PUB}"
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PUB"* ]]
  [ ! -s "${MOCK_LOG}" ]
}

# cosign takes any file as --key, so the public key has to be a PEM public key
# before a version tag is pushed.
@test "refuses a private key as the update public key" {
  { echo '-----BEGIN PRIVATE KEY-----'; echo '-----END PRIVATE KEY-----'; } > "${GVPN_COSIGN_PUB}"
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PUB"* ]]
  [[ "${output}" == *"not a PEM public key"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# A key pasted into a CI variable arrives with CRLF line endings or trailing
# blanks as often as without; it is the same key, so it is accepted.
@test "accepts a public key with CRLF line endings and trailing blanks" {
  printf '%s\r\n' '-----BEGIN PUBLIC KEY----- ' \
    'MCowBQYDK2VwAyEAAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' \
    '-----END PUBLIC KEY-----  ' > "${GVPN_COSIGN_PUB}"
  run "${PUBLISH}"
  [ "${status}" -eq 0 ]
  grep -q '^skopeo copy .*--sign-by-sigstore-private-key' "${MOCK_LOG}"
}

@test "refuses an SSH public key as the update public key" {
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIoperator ops@workstation' > "${GVPN_COSIGN_PUB}"
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PUB"* ]]
  [[ "${output}" == *"not a PEM public key"* ]]
  run grep -e '^skopeo copy' -e '^builder' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses to sign without a passphrase file when there is no terminal" {
  unset GVPN_COSIGN_PASSPHRASE_FILE
  run "${PUBLISH}" < /dev/null
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PASSPHRASE_FILE"* ]]
  run grep -e '^skopeo copy' -e '^builder' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses to start without the signing key" {
  rm "${GVPN_COSIGN_KEY}"
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_KEY"* ]]
  [ ! -s "${MOCK_LOG}" ]
}

@test "passes a passphrase file to the signer when given" {
  export GVPN_COSIGN_PASSPHRASE_FILE="${SANDBOX}/pass"
  echo secret > "${GVPN_COSIGN_PASSPHRASE_FILE}"
  run "${PUBLISH}"
  grep -q -- "--sign-passphrase-file ${GVPN_COSIGN_PASSPHRASE_FILE} " "${MOCK_LOG}"
}

@test "unsigned-probe puts an unsigned copy of the channel image next to it" {
  run "${PUBLISH}" unsigned-probe
  [ "${status}" -eq 0 ]
  grep -qx "skopeo copy --insecure-policy --remove-signatures --format v2s2 docker://${REPO}:canary docker://${REPO}:unsigned-probe" "${MOCK_LOG}"
  run grep -e '^builder' -e 'sign-by' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# A device on another channel must be probed with that channel's image: the
# probe is the only check that a device refuses an unsigned update.
@test "unsigned-probe takes the channel a device tracks" {
  run "${PUBLISH}" unsigned-probe stable
  [ "${status}" -eq 0 ]
  grep -qx "skopeo copy --insecure-policy --remove-signatures --format v2s2 docker://${REPO}:stable docker://${REPO}:unsigned-probe" "${MOCK_LOG}"
}

@test "sigstore attachment lookup works for configurable registry repositories" {
  [[ "$(cat "${ROOTFS}/etc/containers/registries.d/gvpn-exit-os.yaml")" == $'default-docker:\n  use-sigstore-attachments: true' ]]
}

@test "publishing requires an explicit registry repository" {
  run env -u GVPN_IMAGE_REPO "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_IMAGE_REPO"* ]]
  [ ! -s "${MOCK_LOG}" ]
}

@test "aborts when the version lookup fails for any reason but a missing manifest" {
  existing_version_tag unavailable
  run "${PUBLISH}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"503 Service Unavailable"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}
