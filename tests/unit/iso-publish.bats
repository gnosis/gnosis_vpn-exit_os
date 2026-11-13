#!/usr/bin/env bats
# Publish and pull the installer ISO as a signed OCI artifact next to the
# image. The same ISO installs hardware from a USB stick or an Incus VM: it
# detects its install disk, carries no bastion enrollment and no SSH key, and
# is configured on the console, so the published artifact is ready to install
# rather than something every operator rebuilds.

load helpers

PUBLISH="${REPO_ROOT}/tools/publish-iso.sh"
PULL="${REPO_ROOT}/tools/pull-iso.sh"
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

setup() {
  setup_sandbox
  export GVPN_IMAGE_REPO="registry.example.org/fleet/exit-os"
  export GVPN_ISO_REPO="registry.example.org/fleet/exit-os-iso"
  export GVPN_ISO="${SANDBOX}/iso/install.iso"
  export GVPN_ISO_DIR="${SANDBOX}/output/published-iso"
  mkdir -p "$(dirname "${GVPN_ISO}")"
  echo 'iso' >"${GVPN_ISO}"
  echo 1.2.3 >"${GVPN_ISO}.version"
  describe_iso
  # Where --tag-only downloads the artifact it verifies.
  export GVPN_ISO_VERIFY_DIR="${SANDBOX}/verify"
  export GVPN_COSIGN_KEY="${SANDBOX}/cosign.key"
  echo '-----BEGIN PRIVATE KEY-----' >"${GVPN_COSIGN_KEY}"
  echo '-----END PRIVATE KEY-----' >>"${GVPN_COSIGN_KEY}"
  export GVPN_COSIGN_PUB="${SANDBOX}/cosign.pub"
  write_public_key "${GVPN_COSIGN_PUB}"
  export GVPN_COSIGN_PASSPHRASE_FILE="${SANDBOX}/passphrase"
  : >"${GVPN_COSIGN_PASSPHRASE_FILE}"

  # oras: a pushed/tagged reference gets a marker file in the sandbox, and a
  # marked reference resolves to the fixed digest. Unmarked references look
  # like a 404, which is what tag_published expects. The marker of a pushed
  # reference holds its image-id annotation, and a push keeps the checksum
  # file for the test to read. A pull hands out the artifact that
  # make_artifact prepared.
  mock_cmd oras '
ref_key() { printf "%s" "$1" | tr "/:@," "____"; }
case "$1" in
  push)
    ref="$2"
    image=""
    for arg in "$@"; do
      case "${arg}" in org.gvpn-exit.image-id=*) image="${arg#*=}" ;; esac
    done
    cp install.iso.sha256 "${SANDBOX}/pushed.sha256"
    printf "%s" "${image}" >"${SANDBOX}/ref-$(ref_key "${ref}")" ;;
  tag)
    : >"${SANDBOX}/ref-$(ref_key "${2%:*}:$3")" ;;
  manifest)
    ref="${*: -1}"
    marker="${SANDBOX}/ref-$(ref_key "${ref}")"
    if [[ ! -e "${marker}" ]]; then
      echo "not found" >&2
      exit 1
    fi
    if [[ "$*" == *--descriptor* ]]; then
      printf "{\"digest\":\"%s\"}\n" "${MOCK_DIGEST}"
    else
      printf "{\"annotations\":{\"org.gvpn-exit.image-id\":\"%s\"}}\n" "$(cat "${marker}")"
    fi ;;
  pull)
    out=""
    while (( $# > 0 )); do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -d "${SANDBOX}/artifact" ]] || exit 1
    mkdir -p "${out}"
    cp "${SANDBOX}/artifact/"* "${out}/" ;;
esac'
  export MOCK_DIGEST="${DIGEST}"
  mock_cmd cosign '
case "$1" in
  sign-blob)
    bundle=""
    prev=""
    for arg in "$@"; do
      [[ "${prev}" == --bundle ]] && bundle="${arg}"
      case "${arg}" in --bundle=*) bundle="${arg#--bundle=}" ;; esac
      prev="${arg}"
    done
    [[ -n "${bundle}" ]] || exit 1
    echo bundle >"${bundle}" ;;
  verify-blob)
    [[ "$*" == *--bundle* ]] || exit 1
    # A pulled artifact verifies only while its checksum file is the one that
    # make_artifact recorded as signed.
    [[ ! -e "${SANDBOX}/signed.sha256" ]] || cmp -s "${*: -1}" "${SANDBOX}/signed.sha256" ;;
esac'
}

# describe_iso [DISK] [ENROLLMENT] [ACCESS]: the target sidecar the ISO build
# writes beside the local ISO, bound to it by its sha256.
describe_iso() {
  printf 'disk=%s\nenrollment=%s\naccess=%s\nimage=sha256:1d1d1d\nsha256=%s\n' \
    "${1:-auto}" "${2:-none}" "${3:-console}" \
    "$(sha256sum "${GVPN_ISO}" | cut -d' ' -f1)" >"${GVPN_ISO}.target"
}

# make_artifact VERSION [DISK]: the published artifact the oras mock hands
# out, with a real checksum file over the ISO and its sidecars. That checksum
# file is what the publisher signed.
make_artifact() {
  local dir="${SANDBOX}/artifact"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  echo "iso $1" >"${dir}/install.iso"
  echo "$1" >"${dir}/install.iso.version"
  { echo "disk=${2:-auto}"; echo enrollment=none; echo access=console; } >"${dir}/install.iso.target"
  ( cd "${dir}" && sha256sum install.iso install.iso.version install.iso.target >install.iso.sha256 )
  echo bundle >"${dir}/install.iso.sha256.sigstore.json"
  cp "${dir}/install.iso.sha256" "${SANDBOX}/signed.sha256"
}

teardown() {
  teardown_sandbox
}

@test "publish pushes a signed artifact under the version and moves canary" {
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -q '^oras push registry.example.org/fleet/exit-os-iso:1.2.3 --artifact-type application/vnd.gvpn-exit.installer-iso.v1+json' "${MOCK_LOG}"
  grep -q 'org.opencontainers.image.title=ExitOS installer ISO ' "${MOCK_LOG}"
  grep -q 'install.iso:application/x-iso9660-image' "${MOCK_LOG}"
  grep -q 'install.iso.sha256:text/plain' "${MOCK_LOG}"
  grep -q 'install.iso.sha256.sigstore.json:application/vnd.dev.sigstore.bundle.v0.3+json' "${MOCK_LOG}"
  grep -q 'install.iso.target:text/plain' "${MOCK_LOG}"
  grep -q 'org.gvpn-exit.image-id=sha256:1d1d1d ' "${MOCK_LOG}"
  # The signature is on the checksum file, which covers the ISO and both
  # sidecars: nothing a puller trusts is outside it.
  grep -q '^cosign sign-blob .*--bundle .*install.iso.sha256.sigstore.json .*/install.iso.sha256$' "${MOCK_LOG}"
  # The signing config the real-cosign test below checks: no transparency log.
  grep -q "^cosign sign-blob .*--signing-config ${REPO_ROOT}/tools/cosign-signing-config.json " "${MOCK_LOG}"
  grep -q "^cosign verify-blob --key ${GVPN_COSIGN_PUB} --bundle .*install.iso.sha256.sigstore.json .*/install.iso.sha256\$" "${MOCK_LOG}"
  [ "$(awk '{ print $2 }' "${SANDBOX}/pushed.sha256" | sort | tr '\n' ' ')" = "install.iso install.iso.target install.iso.version " ]
  grep -qx "$(sha256sum "${GVPN_ISO}" | cut -d' ' -f1)  install.iso" "${SANDBOX}/pushed.sha256"
  grep -qx 'oras tag registry.example.org/fleet/exit-os-iso:1.2.3 canary' "${MOCK_LOG}"
  [[ "${output}" == *"canary points at it"* ]]
}

# The ISO has a repository of its own, so its tags are the plain version and
# channel: in the image repository, they would replace the image's own tags.
@test "publish and pull refuse to run without an ISO repository apart from the image's" {
  run "${PUBLISH}" 1.2.3
  [ "${status}" -eq 0 ]
  run grep 'registry.example.org/fleet/exit-os:' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  : >"${MOCK_LOG}"
  for repo in "" "${GVPN_IMAGE_REPO}"; do
    export GVPN_ISO_REPO="${repo}"
    run "${PUBLISH}" 1.2.4
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GVPN_ISO_REPO"* ]]
    run "${PULL}" 1.2.3
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GVPN_ISO_REPO"* ]]
  done
  [ ! -s "${MOCK_LOG}" ]
}

@test "an ISO repository needs no image repository, and a malformed one is refused" {
  unset GVPN_IMAGE_REPO
  export GVPN_ISO_REPO="registry.example.org/fleet/exit-os-iso"
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  export GVPN_ISO_REPO="https://registry.example.org/fleet/exit-os-iso:tag"
  run "${PUBLISH}" --no-channel 1.2.4
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_ISO_REPO"* ]]
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_ISO_REPO"* ]]
}

@test "publish --no-channel leaves the channel alone and is idempotent" {
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no channel tag moved"* ]]
  run grep '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  # A CI rerun after a later step failed finds the version and continues.
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already published"* ]]
}

# A rerun rebuilds the image. Its ISO step must stop, so the image step after
# it never publishes a build that differs from the one the published ISO embeds.
@test "publish --no-channel refuses a version that was published from another build" {
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  sed -i 's/^image=.*/image=sha256:2e2e2e/' "${GVPN_ISO}.target"
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"another build"* ]]
  [[ "${output}" == *"sha256:1d1d1d"* ]]
  [ "$(grep -c '^oras push ' "${MOCK_LOG}")" -eq 1 ]
}

# The sidecars are bound to the ISO by its sha256: an ISO that was replaced
# after they were written is not the ISO they describe.
@test "publish refuses an ISO its target sidecar does not describe" {
  echo 'managed iso' >"${GVPN_ISO}"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not describe"* ]]
  sed -i '/^sha256=/d' "${GVPN_ISO}.target"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not describe"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The version is the label of the image the ISO embeds, recorded by the build.
@test "publish refuses an ISO without a version sidecar" {
  rm "${GVPN_ISO}.version"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no version sidecar"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "publish takes the version from the ISO build sidecar" {
  echo 2.0.0 >"${GVPN_ISO}.version"
  run "${PUBLISH}" --no-channel
  [ "${status}" -eq 0 ]
  grep -q '^oras push .*:2.0.0 ' "${MOCK_LOG}"
}

@test "publish refuses a dirty ISO" {
  echo 1.2.3-dirty >"${GVPN_ISO}.version"
  run "${PUBLISH}" 1.2.3-dirty
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"uncommitted source"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "publish refuses to overwrite an already published version" {
  : >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already published"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "publish requires the ISO and the signing and public keys" {
  rm "${GVPN_ISO}"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no ISO"* ]]
  [[ "${output}" == *"just iso-console"* ]]
  echo iso >"${GVPN_ISO}"
  describe_iso
  rm "${GVPN_COSIGN_KEY}"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no signing key"* ]]
  echo key >"${GVPN_COSIGN_KEY}"
  rm "${GVPN_COSIGN_PUB}"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PUB"* ]]
}

@test "publish refuses an ISO whose name is not install.iso" {
  mv "${GVPN_ISO}" "${SANDBOX}/iso/other.iso"
  mv "${GVPN_ISO}.version" "${SANDBOX}/iso/other.iso.version"
  mv "${GVPN_ISO}.target" "${SANDBOX}/iso/other.iso.target"
  GVPN_ISO="${SANDBOX}/iso/other.iso" run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"install.iso"* ]]
}

@test "publish refuses a pinned-disk, bastion or key-configured ISO" {
  local disk
  for disk in nvme0n1 sda; do
    describe_iso "${disk}"
    run "${PUBLISH}" 1.2.3
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"pins install disk ${disk}"* ]]
    [[ "${output}" == *"GVPN_INSTALL_DISK unset"* ]]
  done
  describe_iso auto bastion
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bastion enrollment"* ]]
  describe_iso auto none key
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"installer SSH key"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "publish must sign and verify before it pushes" {
  mock_cmd cosign '
case "$1" in
  verify-blob) exit 1 ;;
esac'
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "cosign 3 accepts the sign-blob invocation the publisher uses" {
  # setup() put a recording cosign on PATH; this test needs the real one.
  rm "${MOCK_BIN}/cosign"
  command -v cosign >/dev/null || skip "cosign is not on PATH"
  export COSIGN_PASSWORD=""
  local keydir="${SANDBOX}/realkeys" blob="${SANDBOX}/realblob"
  mkdir -p "${keydir}"
  echo blob >"${blob}"
  run cosign generate-key-pair --output-key-prefix "${keydir}/cosign"
  [ "${status}" -eq 0 ]
  run cosign sign-blob --yes --key "${keydir}/cosign.key" \
    --signing-config "${REPO_ROOT}/tools/cosign-signing-config.json" \
    --bundle "${keydir}/blob.sigstore.json" "${blob}"
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *deprecated* ]]
  # Nothing went to a transparency log or a timestamp authority.
  [ "$(jq -c '.verificationMaterial | keys' "${keydir}/blob.sigstore.json")" = '["publicKey"]' ]
  run cosign verify-blob --key "${keydir}/cosign.pub" \
    --bundle "${keydir}/blob.sigstore.json" --insecure-ignore-tlog=true "${blob}"
  [ "${status}" -eq 0 ]
}

@test "tag-only ignores a stale local build and moves the channel" {
  : >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3"
  make_artifact 1.2.3
  echo 9.9.9 >"${GVPN_ISO}.version"
  run "${PUBLISH}" --tag-only 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -qx 'oras tag registry.example.org/fleet/exit-os-iso:1.2.3 canary' "${MOCK_LOG}"
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  run grep '^cosign sign-blob ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  # The download it verified is not kept.
  [ -z "$(ls -A "${GVPN_ISO_VERIFY_DIR}")" ]
}

# A channel only moves to an artifact that verifies against the update key,
# like an image promotion.
@test "tag-only verifies the published artifact before it moves the channel" {
  : >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3"
  make_artifact 1.2.3
  run "${PUBLISH}" --tag-only 1.2.3
  [ "${status}" -eq 0 ]
  grep -q "^cosign verify-blob --key ${GVPN_COSIGN_PUB} --bundle .*install.iso.sha256.sigstore.json " "${MOCK_LOG}"
  [ "$(grep -n '^cosign verify-blob ' "${MOCK_LOG}" | head -n1 | cut -d: -f1)" -lt "$(grep -n '^oras tag ' "${MOCK_LOG}" | cut -d: -f1)" ]

  : >"${MOCK_LOG}"
  echo tampered >>"${SANDBOX}/artifact/install.iso.sha256"
  run "${PUBLISH}" --tag-only 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"canary not moved"* ]]
  run grep '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${GVPN_ISO_VERIFY_DIR}")" ]
}

@test "publish-sidecar version disagrees with the argument" {
  echo 2.0.0 >"${GVPN_ISO}.version"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"built as 2.0.0"* ]]
}

@test "pull verifies the checksum and signature and prints the ISO path" {
  make_artifact 1.2.3
  run "${PULL}" 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${SANDBOX}/output/published-iso/install.iso" ]
  grep -q '^oras pull registry.example.org/fleet/exit-os-iso:1.2.3 -o ' "${MOCK_LOG}"
  # The key is GVPN_COSIGN_PUB and the signed blob is the checksum file, which
  # the real sha256sum then checks the ISO and its sidecars against.
  grep -q "^cosign verify-blob --key ${GVPN_COSIGN_PUB} --bundle .*install.iso.sha256.sigstore.json --insecure-ignore-tlog=true .*/install.iso.sha256\$" "${MOCK_LOG}"
  [ "$(cat "${GVPN_ISO_DIR}/install.iso")" = "iso 1.2.3" ]
}

@test "pull canary accepts the version recorded in the artifact" {
  make_artifact 1.2.3
  run "${PULL}" canary
  [ "${status}" -eq 0 ]
  grep -q '^oras pull registry.example.org/fleet/exit-os-iso:canary -o ' "${MOCK_LOG}"
  [ "${output}" = "${SANDBOX}/output/published-iso/install.iso" ]
}

@test "pull fails a checksum or signature mismatch" {
  make_artifact 1.2.3
  echo 'another iso' >"${SANDBOX}/artifact/install.iso"
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"checksum mismatch"* ]]

  make_artifact 1.2.3
  mock_cmd cosign 'exit 1'
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
}

# An old ISO is genuinely signed. Served again under a newer tag, its version
# sidecar has to be edited to match, and the signature covers that sidecar.
@test "pull refuses an old signed ISO re-pushed under a newer version" {
  make_artifact 1.0.0
  echo 2.0.0 >"${SANDBOX}/artifact/install.iso.version"
  run "${PULL}" 2.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"checksum mismatch"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]

  # With the checksum file redone to match, the signature no longer does.
  ( cd "${SANDBOX}/artifact" && sha256sum install.iso install.iso.version install.iso.target >install.iso.sha256 )
  run "${PULL}" 2.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]

  # Unedited, the artifact says which version it is.
  make_artifact 1.0.0
  run "${PULL}" 2.0.0
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"reports version 1.0.0, expected 2.0.0"* ]]
}

# A sidecar the signed checksum file does not list is not verified by it.
@test "pull refuses a checksum file that does not cover the sidecars" {
  make_artifact 1.2.3
  ( cd "${SANDBOX}/artifact" && sha256sum install.iso >install.iso.sha256 )
  cp "${SANDBOX}/artifact/install.iso.sha256" "${SANDBOX}/signed.sha256"
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not cover"* ]]
}

@test "a failed verification leaves an ISO pulled earlier untouched" {
  make_artifact 1.2.3
  run "${PULL}" 1.2.3
  [ "${status}" -eq 0 ]
  make_artifact 1.3.0
  echo 'another iso' >"${SANDBOX}/artifact/install.iso"
  run "${PULL}" 1.3.0
  [ "${status}" -ne 0 ]
  [ "$(cat "${GVPN_ISO_DIR}/install.iso")" = "iso 1.2.3" ]
  [ "$(cat "${GVPN_ISO_DIR}/install.iso.version")" = "1.2.3" ]
  [ "$(ls -d "${GVPN_ISO_DIR}"* | wc -l)" -eq 1 ]
}

@test "pull refuses to replace a directory that is not an ISO download" {
  mkdir -p "${GVPN_ISO_DIR}"
  echo keep >"${GVPN_ISO_DIR}/notes.txt"
  mock_cmd oras 'exit 0'
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.txt"* ]]
  [ -f "${GVPN_ISO_DIR}/notes.txt" ]
}

@test "pull refuses an artifact that pins its install disk" {
  make_artifact 1.2.3 sda
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pins install disk sda"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]
}

@test "pull refuses an artifact whose version does not match the tag" {
  make_artifact 2.0.0
  run "${PULL}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected 1.2.3"* ]]
}
