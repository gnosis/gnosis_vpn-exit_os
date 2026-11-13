#!/usr/bin/env bash
# Publish the installer ISO for the image it installs: a signed OCI artifact
# in a repository of its own (GVPN_ISO_REPO), under VERSION-CHANNEL and,
# unless --no-channel is given, the channel tag. The channel is the one the
# ISO was built for (`just channel=stable iso-console`), recorded in its
# target sidecar: the installed device follows that channel of the image
# repository for its updates, so an ISO under `stable` installs a device on
# `stable`. The one published ISO installs both targets, hardware from a USB
# stick or an Incus VM: it detects its install disk (disk=auto), carries no
# bastion enrollment and no SSH key, and is configured on the console.
#
#   tools/publish-iso.sh [--no-channel] [VERSION]
#   tools/publish-iso.sh --tag-only VERSION CHANNEL
#
# The version is the one in the version sidecar written by the ISO build, the
# version label of the image the ISO embeds; VERSION, when given, has to match
# it. A version built from uncommitted source (`-dirty`) is refused, and so is
# an ISO whose target sidecar does not record its sha256. An ISO is pushed,
# and a channel moved, only while the image repository serves the image the
# ISO embeds under that channel (under the version with --no-channel): a
# device installed from it updates from that channel, so the image is
# published or promoted first. The signature, made with the image-update key
# (GVPN_COSIGN_KEY) and verified against its public half (GVPN_COSIGN_PUB)
# before anything is pushed, is on the checksum file install.iso.sha256, which
# lists the ISO and both sidecars: everything tools/pull-iso.sh trusts is
# covered by it. A VERSION-CHANNEL is published once: when it is there already,
# it is pulled by digest and verified against GVPN_COSIGN_PUB, and when its
# signed target records the image of the local ISO, the local ISO is not
# pushed over it and the channel tag moves to that digest (a version promoted
# to a channel again); when it embeds another build, publishing stops.
# --no-channel leaves the channel tag alone in both cases.
# --tag-only moves CHANNEL to a VERSION-CHANNEL that is already published,
# without a local ISO, after pulling it by digest and verifying it the same
# way.
#
#   GVPN_ISO_REPO                registry repository of the ISO, required, and
#                                not GVPN_IMAGE_REPO
#   GVPN_IMAGE_REPO              registry repository of the image the ISO
#                                installs and its devices update from (required)
#   GVPN_ISO                     ISO path (default: output/iso/bootiso/install.iso)
#   GVPN_COSIGN_KEY              private key (default: cosign.key at repo root)
#   GVPN_COSIGN_PUB              public half (default: keys/cosign.pub)
#   GVPN_COSIGN_PASSPHRASE_FILE  passphrase file, empty for a key without one
#   GVPN_ISO_VERIFY_DIR          where a published ISO is downloaded to verify
#                                it, removed afterwards (default: output)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "${REPO_ROOT}/tools/lib.sh"

REPO="$(iso_repo)" || exit 1
IMAGE_REPO="${GVPN_IMAGE_REPO:?Set GVPN_IMAGE_REPO to the repository of the image the ISO installs}"
ISO="${GVPN_ISO:-${REPO_ROOT}/output/iso/bootiso/install.iso}"
GVPN_COSIGN_KEY="${GVPN_COSIGN_KEY:-${REPO_ROOT}/cosign.key}"
GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB:-${REPO_ROOT}/keys/cosign.pub}"
GVPN_COSIGN_PASSPHRASE_FILE="${GVPN_COSIGN_PASSPHRASE_FILE:-}"
ARTIFACT_TYPE='application/vnd.gvpn-exit.installer-iso.v1+json'
# Manifest annotation: the ID of the image the ISO embeds.
IMAGE_ID_ANNOTATION='org.gvpn-exit.image-id'
VERIFY_ROOT="${GVPN_ISO_VERIFY_DIR:-${REPO_ROOT}/output}"
VERIFY_DIR=""
VERSION_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
VERSION_ARG=""
CHANNEL_ARG=""
MOVE_CHANNEL=1
TAG_ONLY=0
BUNDLE=""
SHA256=""

die() {
  echo "$*" >&2
  exit 1
}

cleanup() {
  rm -f "${SHA256}" "${BUNDLE}"
  [[ -z "${VERIFY_DIR}" ]] || rm -rf "${VERIFY_DIR}"
}

usage() {
  echo "usage: tools/publish-iso.sh [--no-channel] [VERSION]" >&2
  echo "       tools/publish-iso.sh --tag-only VERSION CHANNEL" >&2
  exit 64
}

# The digest of a pushed manifest, or no output when the reference is not
# published. Any other registry error aborts: treating it as "not published"
# could overwrite a version that exists.
remote_digest() {
  local ref="$1" error
  if error="$(oras manifest fetch --descriptor "${ref}" 2>&1 >/dev/null)"; then
    oras manifest fetch --descriptor "${ref}" | jq -r '.digest'
    return 0
  fi
  grep -Eiq 'not found|manifest unknown|404' <<< "${error}" || die "cannot tell whether ${ref} is published: ${error}"
  return 1
}

tag_published() {
  remote_digest "${REPO}:$1" >/dev/null
}

resolved_version() {
  local sidecar="${ISO}.version"
  # The sidecar holds the version label of the image the ISO embeds. The
  # checkout may have moved on since the build, so it is no substitute.
  [[ -f "${sidecar}" ]] \
    || die "no version sidecar at ${sidecar}; rebuild the ISO with: just iso-console"
  if [[ -n "${VERSION_ARG}" ]]; then
    if [[ -f "${sidecar}" && "$(< "${sidecar}")" != "${VERSION_ARG}" ]]; then
      die "${ISO} was built as $(< "${sidecar}"), not ${VERSION_ARG}; rebuild or publish the matching version"
    fi
    printf '%s\n' "${VERSION_ARG}"
    return 0
  fi
  cat "${sidecar}"
}

# The channel the local ISO was built for, from its target sidecar.
resolved_channel() {
  local target="${ISO}.target" channel
  [[ -f "${target}" ]] \
    || die "no target sidecar at ${target}; rebuild the ISO with: just iso-console"
  channel="$(sed -n 's/^channel=//p' "${target}")"
  [[ -n "${channel}" ]] \
    || die "${target} does not record the channel the installed device follows; rebuild the ISO with: just iso-console"
  [[ "${channel}" =~ ${GVPN_CHANNEL_RE} ]] \
    || die "${target} records channel '${channel}': a device follows canary or stable"
  printf '%s\n' "${channel}"
}

# verify_published TAG DIGEST
# Pull DIGEST and verify it against GVPN_COSIGN_PUB as the published TAG, as
# tools/pull-iso.sh does for an operator: by digest, so what is verified is
# what the caller then tags. The download is removed on exit.
verify_published() {
  local tag="$1" digest="$2"
  mkdir -p "${VERIFY_ROOT}"
  VERIFY_DIR="$(mktemp -d "${VERIFY_ROOT}/.tag-iso-XXXXXX")"
  trap cleanup EXIT
  GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB}" GVPN_ISO_DIR="${VERIFY_DIR}/iso" \
    "${REPO_ROOT}/tools/pull-iso.sh" "${tag}@${digest}" >/dev/null
}

# The image the ISO verify_published downloaded embeds, from its signed target.
verified_image() {
  sed -n 's/^image=//p' "${VERIFY_DIR}/iso/install.iso.target"
}

# require_image TAG IMAGE WHAT
# Stop unless the image repository serves, under TAG, the image with ID IMAGE,
# the one the ISO embeds. The ID podman gives an image, as the ISO build
# records it, is the digest of the image's config, which the manifest names
# with a sha256: in front. WHAT ends the message: what did not happen.
require_image() {
  local ref="${IMAGE_REPO}:$1" image="${2#sha256:}" what="$3" config
  [[ -n "${image}" ]] || die "no embedded image recorded to compare with ${ref}; ${what}"
  config="$(skopeo inspect --raw "docker://${ref}" | jq -r '.config.digest // empty')" \
    || die "cannot read ${ref}, which has to serve the image the ISO embeds (sha256:${image}); ${what}"
  [[ "${config#sha256:}" == "${image}" ]] \
    || die "${ref} serves image ${config:-(no config)}, not sha256:${image} that the ISO embeds; ${what}"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --no-channel) MOVE_CHANNEL=0 ;;
      --tag-only) TAG_ONLY=1 ;;
      -h|--help) usage ;;
      --*) die "unknown option '$1'" ;;
      *)
        if [[ -z "${VERSION_ARG}" ]]; then
          VERSION_ARG="$1"
        elif (( TAG_ONLY )) && [[ -z "${CHANNEL_ARG}" ]]; then
          CHANNEL_ARG="$1"
        else
          usage
        fi
        ;;
    esac
    shift
  done
}

# move_channel CHANNEL DIGEST
# Move the channel tag to an already pushed artifact, by the digest that was
# pushed or verified; this only adds a tag.
move_channel() {
  local to_tag="$1" expected="$2" moved_digest
  oras tag "${REPO}@${expected}" "${to_tag}" >/dev/null
  moved_digest="$(remote_digest "${REPO}:${to_tag}")" \
    || die "${REPO}:${to_tag} is not readable after tagging"
  [[ "${moved_digest}" == "${expected}" ]] \
    || die "${REPO}:${to_tag} points at ${moved_digest}, expected ${expected}"
}

publish() {
  local version tag channel_tag pushed_digest iso_dir iso_name target disk image published
  # --tag-only moves a channel for a version that is already in the registry;
  # it must not be blocked by a locally built ISO at another commit.
  if (( TAG_ONLY )); then
    [[ -n "${VERSION_ARG}" && -n "${CHANNEL_ARG}" ]] || die "--tag-only needs VERSION and CHANNEL"
    [[ "${CHANNEL_ARG}" =~ ${GVPN_CHANNEL_RE} ]] \
      || die "invalid channel '${CHANNEL_ARG}': an ISO follows canary or stable"
    version="${VERSION_ARG}"
    channel_tag="${CHANNEL_ARG}"
  else
    version="$(resolved_version)"
    channel_tag="$(resolved_channel)"
  fi
  [[ "${version}" =~ ${VERSION_RE} ]] || die "unusable ISO version '${version}'"
  [[ "${version}" != *-dirty ]] || die "the ISO was built from uncommitted source (${version}); commit and rebuild it before publishing"
  tag="${version}-${channel_tag}"
  (( ${#tag} <= 128 )) || die "version '${version}' makes an OCI tag longer than 128 characters"

  if (( TAG_ONLY )); then
    pushed_digest="$(remote_digest "${REPO}:${tag}")" \
      || die "${REPO}:${tag} is not published"
    verify_published "${tag}" "${pushed_digest}" \
      || die "${REPO}:${tag} does not verify against ${GVPN_COSIGN_PUB}; ${channel_tag} not moved"
    require_image "${channel_tag}" "$(verified_image)" "${channel_tag} not moved"
    move_channel "${channel_tag}" "${pushed_digest}"
    echo "${REPO}:${channel_tag} now points at ${pushed_digest} (${REPO}:${tag})"
    return 0
  fi

  if tag_published "${tag}"; then
    # A version names one build. A local ISO that embeds another image than
    # the published one, as its signed target records it, comes from a
    # rebuild of that version: it is not pushed over the published ISO, and
    # no channel moves.
    pushed_digest="$(remote_digest "${REPO}:${tag}")" \
      || die "${REPO}:${tag} is not readable"
    verify_published "${tag}" "${pushed_digest}" \
      || die "${REPO}:${tag} does not verify against ${GVPN_COSIGN_PUB}; ${channel_tag} not moved"
    image="$(sed -n 's/^image=//p' "${ISO}.target")"
    published="$(verified_image)"
    [[ -n "${image}" && "${image}" == "${published}" ]] \
      || die "${REPO}:${tag} is already published from another build of ${version} (image ${published:-not recorded}, this build ${image:-not recorded}); commit, rebuild, then publish"
    if (( MOVE_CHANNEL )); then
      require_image "${channel_tag}" "${published}" "${channel_tag} not moved"
      move_channel "${channel_tag}" "${pushed_digest}"
      echo "${REPO}:${tag} is already published; ${channel_tag} now points at it (${pushed_digest})"
    else
      echo "${REPO}:${tag} is already published; leaving it unchanged"
    fi
    return 0
  fi

  [[ -s "${ISO}" ]] || die "no ISO at ${ISO}; build one with: just iso-console"
  [[ "$(basename "${ISO}")" == install.iso ]] \
    || die "the published ISO must be named install.iso, got $(basename "${ISO}")"
  target="${ISO}.target"
  [[ -f "${target}" ]] \
    || die "no target sidecar at ${target}; rebuild the ISO with: just iso-console"
  disk="$(sed -n 's/^disk=//p' "${target}")"
  grep -qx 'disk=auto' "${target}" \
    || die "${ISO} pins install disk ${disk:-(none recorded)}; the published ISO must detect its disk, build it with GVPN_INSTALL_DISK unset (just iso-console)"
  grep -qx 'enrollment=none' "${target}" \
    || die "${ISO} carries bastion enrollment data; publish an unmanaged ISO"
  grep -qx 'access=console' "${target}" \
    || die "${ISO} carries an installer SSH key; publish a console-configured ISO (just iso-console)"
  # The sidecar is bound to the ISO it was written for: an ISO that was
  # replaced since is not the one the lines above were checked for.
  grep -qx "sha256=$(sha256sum "${ISO}" | cut -d' ' -f1)" "${target}" \
    || die "${target} does not describe ${ISO} (no matching sha256); rebuild the ISO with: just iso-console"
  image="$(sed -n 's/^image=//p' "${target}")"
  [[ -n "${image}" ]] || die "${target} does not record the embedded image; rebuild the ISO with: just iso-console"
  [[ -r "${GVPN_COSIGN_KEY}" ]] || die "GVPN_COSIGN_KEY: no signing key at ${GVPN_COSIGN_KEY}"
  require_public_key "${GVPN_COSIGN_PUB}" || exit 1
  if (( MOVE_CHANNEL )); then
    require_image "${channel_tag}" "${image}" "nothing pushed"
  else
    require_image "${version}" "${image}" "nothing pushed"
  fi

  if [[ -n "${GVPN_COSIGN_PASSPHRASE_FILE}" ]]; then
    COSIGN_PASSWORD="$(< "${GVPN_COSIGN_PASSPHRASE_FILE}")"
    export COSIGN_PASSWORD
  elif [[ ! -t 0 ]]; then
    die "GVPN_COSIGN_PASSPHRASE_FILE is not set and stdin is not a terminal: set it to a file holding the signing key's passphrase, or to an empty file for a key without one"
  fi

  iso_dir="$(cd "$(dirname "${ISO}")" && pwd)"
  iso_name="$(basename "${ISO}")"
  SHA256="${iso_dir}/${iso_name}.sha256"
  BUNDLE="${iso_dir}/${iso_name}.sha256.sigstore.json"
  trap cleanup EXIT
  # The checksum file lists the ISO and both sidecars and is what gets signed,
  # so the version and the target are covered by the signature like the ISO.
  ( cd "${iso_dir}" && sha256sum "${iso_name}" "${iso_name}.version" "${iso_name}.target" > "${iso_name}.sha256" )
  # cosign 3.x writes the signature and verification material as one bundle.
  # A local key with no transparency log matches the image's skopeo signature
  # policy: the device trusts the key, not Rekor. The signing config lists no
  # transparency log and no timestamp authority, so nothing leaves this host.
  cosign sign-blob --yes --key "${GVPN_COSIGN_KEY}" \
    --signing-config "${REPO_ROOT}/tools/cosign-signing-config.json" \
    --bundle "${BUNDLE}" "${SHA256}" >/dev/null
  cosign verify-blob --key "${GVPN_COSIGN_PUB}" --bundle "${BUNDLE}" \
    --insecure-ignore-tlog=true "${SHA256}" >/dev/null \
    || die "the signature on ${SHA256} does not verify against ${GVPN_COSIGN_PUB}; nothing pushed"

  # Push from the ISO's directory, so the artifact stores install.iso and the
  # sidecars at the root instead of recreating the build path on pull.
  (
    cd "${iso_dir}"
    oras push "${REPO}:${tag}" \
      --artifact-type "${ARTIFACT_TYPE}" \
      --annotation "org.opencontainers.image.version=${version}" \
      --annotation "org.opencontainers.image.title=ExitOS installer ISO" \
      --annotation "${IMAGE_ID_ANNOTATION}=${image}" \
      "${iso_name}:application/x-iso9660-image" \
      "${iso_name}.sha256:text/plain" \
      "${iso_name}.sha256.sigstore.json:application/vnd.dev.sigstore.bundle.v0.3+json" \
      "${iso_name}.version:text/plain" \
      "${iso_name}.target:text/plain" >/dev/null
  )
  pushed_digest="$(remote_digest "${REPO}:${tag}")" \
    || die "${REPO}:${tag} is not readable after the push"

  if (( MOVE_CHANNEL )); then
    move_channel "${channel_tag}" "${pushed_digest}"
    echo "published ${REPO}:${tag} (${pushed_digest}), signed; ${channel_tag} points at it"
  else
    echo "published ${REPO}:${tag} (${pushed_digest}), signed; no channel tag moved"
  fi
}

main() {
  cd "${REPO_ROOT}"
  parse_args "$@"
  publish
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
