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
    repo="${2%@*}"
    : >"${SANDBOX}/ref-$(ref_key "${repo%:*}:$3")" ;;
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
  # skopeo: the image repository. A tag given to serve_image has a manifest
  # whose config digest is the image ID it was given; any other tag is
  # unknown to the registry.
  mock_cmd skopeo '
ref="${*: -1}"
marker="${SANDBOX}/image-$(printf "%s" "${ref#docker://}" | tr "/:@" "___")"
if [[ ! -e "${marker}" ]]; then
  echo "manifest unknown" >&2
  exit 1
fi
printf "{\"config\":{\"digest\":\"%s\"}}\n" "$(cat "${marker}")"'
  serve_image canary
  serve_image 1.2.3
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

# describe_iso [DISK] [ENROLLMENT] [ACCESS] [CHANNEL]: the target sidecar the
# ISO build writes beside the local ISO, bound to it by its sha256. The image
# is recorded as podman reports its ID, without the sha256: of the registry's
# config digest.
describe_iso() {
  printf 'disk=%s\nenrollment=%s\naccess=%s\nchannel=%s\nimage=1d1d1d\nsha256=%s\n' \
    "${1:-auto}" "${2:-none}" "${3:-console}" "${4:-canary}" \
    "$(sha256sum "${GVPN_ISO}" | cut -d' ' -f1)" >"${GVPN_ISO}.target"
}

# serve_image TAG [CONFIG_DIGEST]: the image repository serves, under TAG, the
# image with that config digest, by default the image the ISO embeds.
serve_image() {
  printf '%s' "${2:-sha256:1d1d1d}" >"${SANDBOX}/image-registry.example.org_fleet_exit-os_$1"
}

# make_artifact VERSION [DISK] [CHANNEL] [IMAGE]: the published artifact the
# oras mock hands out, with a real checksum file over the ISO and its
# sidecars. That checksum file is what the publisher signed.
make_artifact() {
  local dir="${SANDBOX}/artifact"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  echo "iso $1" >"${dir}/install.iso"
  echo "$1" >"${dir}/install.iso.version"
  { echo "disk=${2:-auto}"; echo enrollment=none; echo access=console; echo "channel=${3:-canary}"; echo "image=${4:-1d1d1d}"; } >"${dir}/install.iso.target"
  ( cd "${dir}" && sha256sum install.iso install.iso.version install.iso.target >install.iso.sha256 )
  echo bundle >"${dir}/install.iso.sha256.sigstore.json"
  cp "${dir}/install.iso.sha256" "${SANDBOX}/signed.sha256"
}

teardown() {
  teardown_sandbox
}

@test "publish pushes a signed artifact under the version and its channel and moves canary" {
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -q '^oras push registry.example.org/fleet/exit-os-iso:1.2.3-canary --artifact-type application/vnd.gvpn-exit.installer-iso.v1+json' "${MOCK_LOG}"
  grep -q 'org.opencontainers.image.title=ExitOS installer ISO ' "${MOCK_LOG}"
  grep -q 'install.iso:application/x-iso9660-image' "${MOCK_LOG}"
  grep -q 'install.iso.sha256:text/plain' "${MOCK_LOG}"
  grep -q 'install.iso.sha256.sigstore.json:application/vnd.dev.sigstore.bundle.v0.3+json' "${MOCK_LOG}"
  grep -q 'install.iso.target:text/plain' "${MOCK_LOG}"
  grep -q 'org.gvpn-exit.image-id=1d1d1d ' "${MOCK_LOG}"
  # The signature is on the checksum file, which covers the ISO and both
  # sidecars: nothing a puller trusts is outside it.
  grep -q '^cosign sign-blob .*--bundle .*install.iso.sha256.sigstore.json .*/install.iso.sha256$' "${MOCK_LOG}"
  # The signing config the real-cosign test below checks: no transparency log.
  grep -q "^cosign sign-blob .*--signing-config ${REPO_ROOT}/tools/cosign-signing-config.json " "${MOCK_LOG}"
  grep -q "^cosign verify-blob --key ${GVPN_COSIGN_PUB} --bundle .*install.iso.sha256.sigstore.json .*/install.iso.sha256\$" "${MOCK_LOG}"
  [ "$(awk '{ print $2 }' "${SANDBOX}/pushed.sha256" | sort | tr '\n' ' ')" = "install.iso install.iso.target install.iso.version " ]
  grep -qx "$(sha256sum "${GVPN_ISO}" | cut -d' ' -f1)  install.iso" "${SANDBOX}/pushed.sha256"
  # The channel moves to the digest that was pushed, not to whatever the
  # version tag points at by then.
  grep -qx "oras tag registry.example.org/fleet/exit-os-iso@${DIGEST} canary" "${MOCK_LOG}"
  [[ "${output}" == *"canary points at it"* ]]
}

# The ISO installs a device that follows one channel, the one it was built
# for: that channel is part of its immutable tag and is the tag that moves.
@test "publish puts an ISO built for stable under stable" {
  serve_image stable
  describe_iso auto none console stable
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -q '^oras push registry.example.org/fleet/exit-os-iso:1.2.3-stable ' "${MOCK_LOG}"
  grep -qx "oras tag registry.example.org/fleet/exit-os-iso@${DIGEST} stable" "${MOCK_LOG}"
  run grep ' canary$' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [[ "${output}" != *canary* ]]
}

# A device installed from the ISO updates from the image channel, so an ISO
# goes out for a channel only once that channel serves the image the ISO
# embeds: the image is promoted first. A local build of a version has another
# image ID than the published one.
@test "publish pushes no ISO for a channel that does not serve its image" {
  describe_iso auto none console stable
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"registry.example.org/fleet/exit-os:stable"* ]]
  [[ "${output}" == *"nothing pushed"* ]]

  serve_image stable sha256:2e2e2e
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sha256:2e2e2e"* ]]
  [[ "${output}" == *"nothing pushed"* ]]
  run grep -e '^oras push ' -e '^oras tag ' -e '^cosign sign-blob ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  grep -qx 'skopeo inspect --raw docker://registry.example.org/fleet/exit-os:stable' "${MOCK_LOG}"
}

# --no-channel moves nothing, so the image of the version is the one to match.
@test "publish --no-channel pushes no ISO for a version whose image is not published" {
  serve_image canary sha256:2e2e2e
  serve_image 1.2.3 sha256:3f3f3f
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"registry.example.org/fleet/exit-os:1.2.3"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  serve_image 1.2.3
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
}

@test "publish refuses an ISO that does not record the channel its devices follow" {
  sed -i '/^channel=/d' "${GVPN_ISO}.target"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"channel"* ]]
  sed -i '1i channel=latest' "${GVPN_ISO}.target"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"canary or stable"* ]]
  run grep '^oras ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The ISO has a repository of its own, so its channel tags are the image's
# channel names: in the image repository, they would replace the image's own.
@test "publish and pull refuse to run without an ISO repository apart from the image's" {
  run "${PUBLISH}" 1.2.3
  [ "${status}" -eq 0 ]
  run grep '^oras .*registry.example.org/fleet/exit-os[:@]' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  : >"${MOCK_LOG}"
  for repo in "" "${GVPN_IMAGE_REPO}"; do
    export GVPN_ISO_REPO="${repo}"
    run "${PUBLISH}" 1.2.4
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GVPN_ISO_REPO"* ]]
    run "${PULL}" 1.2.3-canary
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GVPN_ISO_REPO"* ]]
  done
  [ ! -s "${MOCK_LOG}" ]
}

# Publishing checks the image the ISO embeds in the image repository; pulling
# the ISO does not need it.
@test "pull needs no image repository, publish does, and a malformed ISO repository is refused" {
  unset GVPN_IMAGE_REPO
  export GVPN_ISO_REPO="registry.example.org/fleet/exit-os-iso"
  make_artifact 1.2.3
  run "${PULL}" 1.2.3-canary
  [ "${status}" -eq 0 ]
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_IMAGE_REPO"* ]]
  run grep -e '^oras push ' -e '^cosign sign-blob ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  export GVPN_ISO_REPO="https://registry.example.org/fleet/exit-os-iso:tag"
  run "${PUBLISH}" --no-channel 1.2.4
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_ISO_REPO"* ]]
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_ISO_REPO"* ]]
}

@test "publish --no-channel leaves the channel alone and is idempotent" {
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no channel tag moved"* ]]
  run grep '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  # Run again for the same image, it finds the ISO published and leaves it.
  make_artifact 1.2.3
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already published"* ]]
  [ "$(grep -c '^oras push ' "${MOCK_LOG}")" -eq 1 ]
}

# A <version>-<channel> names one build of the ISO: a rebuild of the version
# from another image is not pushed over it.
@test "publish --no-channel refuses a version that was published from another build" {
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -eq 0 ]
  make_artifact 1.2.3
  sed -i 's/^image=.*/image=2e2e2e/' "${GVPN_ISO}.target"
  run "${PUBLISH}" --no-channel 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"another build"* ]]
  [[ "${output}" == *"1d1d1d"* ]]
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
  serve_image 2.0.0
  run "${PUBLISH}" --no-channel
  [ "${status}" -eq 0 ]
  grep -q '^oras push .*:2.0.0-canary ' "${MOCK_LOG}"
}

@test "publish refuses a dirty ISO" {
  echo 1.2.3-dirty >"${GVPN_ISO}.version"
  run "${PUBLISH}" 1.2.3-dirty
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"uncommitted source"* ]]
  run grep '^oras push ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# A version is promoted to a channel again when the channel went back to it.
# Its ISO is published already, so the channel tag moves to that one, after it
# verifies, and the ISO built for this promotion is not pushed over it.
@test "publish moves the channel to an ISO that is already published for the same image" {
  printf '1d1d1d' >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3-canary"
  make_artifact 1.2.3
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already published"* ]]
  # What is verified and what is tagged is the digest read first, not
  # whatever the tag points at by then.
  grep -q "^oras pull registry.example.org/fleet/exit-os-iso@${DIGEST} -o " "${MOCK_LOG}"
  grep -qx "oras tag registry.example.org/fleet/exit-os-iso@${DIGEST} canary" "${MOCK_LOG}"
  [ "$(grep -n '^cosign verify-blob ' "${MOCK_LOG}" | head -n1 | cut -d: -f1)" -lt "$(grep -n '^oras tag ' "${MOCK_LOG}" | cut -d: -f1)" ]
  run grep -e '^oras push ' -e '^cosign sign-blob ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${GVPN_ISO_VERIFY_DIR}")" ]

  # Moved back, the image channel has to serve that image too.
  : >"${MOCK_LOG}"
  serve_image canary sha256:2e2e2e
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"canary not moved"* ]]
  run grep '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The image a published ISO embeds is read from its signed target, not from
# the manifest annotation, which anyone with push access can write.
@test "publish refuses to overwrite a version that was published from another build" {
  printf '1d1d1d' >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3-canary"
  make_artifact 1.2.3 auto canary 2e2e2e
  run "${PUBLISH}" 1.2.3
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"another build"* ]]
  [[ "${output}" == *"2e2e2e"* ]]
  run grep -e '^oras push ' -e '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "publish moves no channel to an already published ISO that does not verify" {
  printf '1d1d1d' >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3-canary"
  make_artifact 1.2.3
  echo tampered >>"${SANDBOX}/artifact/install.iso.sha256"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
  [[ "${output}" == *"canary not moved"* ]]
  run grep -e '^oras push ' -e '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${GVPN_ISO_VERIFY_DIR}")" ]
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
  : >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3-stable"
  make_artifact 1.2.3 auto stable
  serve_image stable
  echo 9.9.9 >"${GVPN_ISO}.version"
  sed -i 's/^image=.*/image=9e9e9e/' "${GVPN_ISO}.target"
  run "${PUBLISH}" --tag-only 1.2.3 stable
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -q "^oras pull registry.example.org/fleet/exit-os-iso@${DIGEST} -o " "${MOCK_LOG}"
  grep -qx "oras tag registry.example.org/fleet/exit-os-iso@${DIGEST} stable" "${MOCK_LOG}"
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
  : >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3-canary"
  make_artifact 1.2.3
  run "${PUBLISH}" --tag-only 1.2.3 canary
  [ "${status}" -eq 0 ]
  grep -q "^cosign verify-blob --key ${GVPN_COSIGN_PUB} --bundle .*install.iso.sha256.sigstore.json " "${MOCK_LOG}"
  [ "$(grep -n '^cosign verify-blob ' "${MOCK_LOG}" | head -n1 | cut -d: -f1)" -lt "$(grep -n '^oras tag ' "${MOCK_LOG}" | cut -d: -f1)" ]

  : >"${MOCK_LOG}"
  echo tampered >>"${SANDBOX}/artifact/install.iso.sha256"
  run "${PUBLISH}" --tag-only 1.2.3 canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"canary not moved"* ]]
  run grep '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${GVPN_ISO_VERIFY_DIR}")" ]
}

# The ISO channel follows the image channel: it never points at an ISO whose
# devices would update away from the image it installs.
@test "tag-only moves no channel past the image the image channel serves" {
  : >"${SANDBOX}/ref-registry.example.org_fleet_exit-os-iso_1.2.3-stable"
  make_artifact 1.2.3 auto stable
  run "${PUBLISH}" --tag-only 1.2.3 stable
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"stable not moved"* ]]
  serve_image stable sha256:2e2e2e
  run "${PUBLISH}" --tag-only 1.2.3 stable
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sha256:2e2e2e"* ]]
  [[ "${output}" == *"stable not moved"* ]]
  run grep '^oras tag ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  [ -z "$(ls -A "${GVPN_ISO_VERIFY_DIR}")" ]
}

@test "tag-only needs the version and a channel that exists" {
  run "${PUBLISH}" --tag-only 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--tag-only needs VERSION and CHANNEL"* ]]
  run "${PUBLISH}" --tag-only 1.2.3 latest
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"canary or stable"* ]]
  run grep '^oras ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "publish-sidecar version disagrees with the argument" {
  echo 2.0.0 >"${GVPN_ISO}.version"
  run "${PUBLISH}" 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"built as 2.0.0"* ]]
}

@test "pull verifies the checksum and signature and prints the ISO path" {
  make_artifact 1.2.3
  run "${PULL}" 1.2.3-canary
  echo "${output}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${SANDBOX}/output/published-iso/install.iso" ]
  grep -q '^oras pull registry.example.org/fleet/exit-os-iso:1.2.3-canary -o ' "${MOCK_LOG}"
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
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"checksum mismatch"* ]]

  make_artifact 1.2.3
  mock_cmd cosign 'exit 1'
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
}

# An old ISO is genuinely signed. Served again under a newer tag, its version
# sidecar has to be edited to match, and the signature covers that sidecar.
@test "pull refuses an old signed ISO re-pushed under a newer version" {
  make_artifact 1.0.0
  echo 2.0.0 >"${SANDBOX}/artifact/install.iso.version"
  run "${PULL}" 2.0.0-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"checksum mismatch"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]

  # With the checksum file redone to match, the signature no longer does.
  ( cd "${SANDBOX}/artifact" && sha256sum install.iso install.iso.version install.iso.target >install.iso.sha256 )
  run "${PULL}" 2.0.0-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]

  # Unedited, the artifact says which version it is.
  make_artifact 1.0.0
  run "${PULL}" 2.0.0-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"reports version 1.0.0 on canary, expected 2.0.0-canary"* ]]
}

# A sidecar the signed checksum file does not list is not verified by it.
@test "pull refuses a checksum file that does not cover the sidecars" {
  make_artifact 1.2.3
  ( cd "${SANDBOX}/artifact" && sha256sum install.iso >install.iso.sha256 )
  cp "${SANDBOX}/artifact/install.iso.sha256" "${SANDBOX}/signed.sha256"
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not cover"* ]]
}

@test "a failed verification leaves an ISO pulled earlier untouched" {
  make_artifact 1.2.3
  run "${PULL}" 1.2.3-canary
  [ "${status}" -eq 0 ]
  make_artifact 1.3.0
  echo 'another iso' >"${SANDBOX}/artifact/install.iso"
  run "${PULL}" 1.3.0-canary
  [ "${status}" -ne 0 ]
  [ "$(cat "${GVPN_ISO_DIR}/install.iso")" = "iso 1.2.3" ]
  [ "$(cat "${GVPN_ISO_DIR}/install.iso.version")" = "1.2.3" ]
  [ "$(ls -d "${GVPN_ISO_DIR}"* | wc -l)" -eq 1 ]
}

@test "pull refuses to replace a directory that is not an ISO download" {
  mkdir -p "${GVPN_ISO_DIR}"
  echo keep >"${GVPN_ISO_DIR}/notes.txt"
  mock_cmd oras 'exit 0'
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.txt"* ]]
  [ -f "${GVPN_ISO_DIR}/notes.txt" ]
}

@test "pull refuses an artifact that pins its install disk" {
  make_artifact 1.2.3 sda
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"pins install disk sda"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]
}

@test "pull refuses an artifact whose version does not match the tag" {
  make_artifact 2.0.0
  run "${PULL}" 1.2.3-canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected 1.2.3-canary"* ]]
}

# The channel is what the installed device follows for its updates, so the
# channel tag and the ISO behind it have to agree.
@test "pull refuses an ISO that follows another channel than its tag" {
  make_artifact 1.2.3 auto canary
  run "${PULL}" stable
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"follows canary, not stable"* ]]
  run "${PULL}" 1.2.3-stable
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected 1.2.3-stable"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]

  make_artifact 1.2.3 auto stable
  run "${PULL}" stable
  [ "${status}" -eq 0 ]
}

# An ISO published before the target recorded the channel is still signed, but
# nothing says which channel its devices follow.
@test "pull refuses an artifact that does not record its channel" {
  make_artifact 1.2.3
  sed -i '/^channel=/d' "${SANDBOX}/artifact/install.iso.target"
  ( cd "${SANDBOX}/artifact" && sha256sum install.iso install.iso.version install.iso.target >install.iso.sha256 )
  cp "${SANDBOX}/artifact/install.iso.sha256" "${SANDBOX}/signed.sha256"
  run "${PULL}" canary
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"records no channel"* ]]
  [[ "${output}" == *"promote"* ]]
  [ ! -e "${GVPN_ISO_DIR}" ]
}

# Every published ISO is tagged with its channel; a bare version is an ISO tag
# of the earlier layout and is refused before anything is downloaded.
@test "pull refuses a reference that names no channel" {
  make_artifact 1.2.3
  run "${PULL}" 1.2.3
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"VERSION-CHANNEL"* ]]
  [[ "${output}" == *"1.2.3-canary"* ]]
  run grep '^oras ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# With a digest the pull reads that manifest and still checks the artifact
# against the reference: the publisher verifies exactly what it then tags.
@test "pull by digest reads that manifest and checks it against the reference" {
  make_artifact 1.2.3
  run "${PULL}" "1.2.3-canary@${DIGEST}"
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -q "^oras pull registry.example.org/fleet/exit-os-iso@${DIGEST} -o " "${MOCK_LOG}"
  run "${PULL}" "1.2.3-stable@${DIGEST}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected 1.2.3-stable"* ]]
  : >"${MOCK_LOG}"
  run "${PULL}" "1.2.3-canary@sha256:abc"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"digest"* ]]
  run grep '^oras ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}
