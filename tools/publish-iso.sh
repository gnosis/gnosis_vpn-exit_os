#!/usr/bin/env bash
# Publish the installer ISO next to the image it installs: a signed OCI
# artifact in the same registry repository, under iso-<version> and, unless
# --no-channel is given, the iso-canary channel tag. The one published ISO
# installs both targets, hardware from a USB stick or an Incus VM: it detects
# its install disk (disk=auto), carries no bastion enrollment and no SSH key,
# and is configured on the console.
#
#   tools/publish-iso.sh [--no-channel] [VERSION]
#   tools/publish-iso.sh --tag-only VERSION
#
# The version is the one in the version sidecar written by the ISO build, the
# version label of the image the ISO embeds; VERSION, when given, has to match
# it. A version built from uncommitted source (`-dirty`) is refused, and so is
# an ISO whose target sidecar does not record its sha256. The signature, made
# with the image-update key (GVPN_COSIGN_KEY) and verified against its public
# half (GVPN_COSIGN_PUB) before anything is pushed, is on the checksum file
# install.iso.sha256, which lists the ISO and both sidecars: everything
# tools/pull-iso.sh trusts is covered by it. --no-channel is idempotent for
# one build: an already published version is left alone when it embeds the
# image of the local ISO, and refused when it embeds another build, so a CI
# rerun that rebuilt the image stops before it pushes that image.
# --tag-only moves iso-canary to a version that is already published,
# without rebuilding or re-signing it, after pulling that version and
# verifying it against GVPN_COSIGN_PUB.
#
#   GVPN_ISO_REPO                registry repository of the ISO (default:
#                                GVPN_IMAGE_REPO; one of the two is required)
#   GVPN_ISO                     ISO path (default: output/iso/bootiso/install.iso)
#   GVPN_COSIGN_KEY              private key (default: cosign.key at repo root)
#   GVPN_COSIGN_PUB              public half (default: keys/cosign.pub)
#   GVPN_COSIGN_PASSPHRASE_FILE  passphrase file, empty for a key without one
#   GVPN_ISO_VERIFY_DIR          where --tag-only downloads the version it
#                                verifies, removed afterwards (default: output)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "${REPO_ROOT}/tools/lib.sh"

REPO="$(iso_repo)" || exit 1
ISO="${GVPN_ISO:-${REPO_ROOT}/output/iso/bootiso/install.iso}"
GVPN_COSIGN_KEY="${GVPN_COSIGN_KEY:-${REPO_ROOT}/cosign.key}"
GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB:-${REPO_ROOT}/keys/cosign.pub}"
GVPN_COSIGN_PASSPHRASE_FILE="${GVPN_COSIGN_PASSPHRASE_FILE:-}"
CHANNEL=canary
ARTIFACT_TYPE='application/vnd.gvpn-exit.installer-iso.v1+json'
# Manifest annotation: the ID of the image the ISO embeds.
IMAGE_ID_ANNOTATION='org.gvpn-exit.image-id'
VERIFY_ROOT="${GVPN_ISO_VERIFY_DIR:-${REPO_ROOT}/output}"
VERIFY_DIR=""
VERSION_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
VERSION_ARG=""
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
  echo "       tools/publish-iso.sh --tag-only VERSION" >&2
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
  remote_digest "${REPO}:iso-$1" >/dev/null
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

# Pull the published version and verify it against GVPN_COSIGN_PUB, as
# tools/pull-iso.sh does for an operator. The download is not kept.
verify_published() {
  local version="$1"
  mkdir -p "${VERIFY_ROOT}"
  VERIFY_DIR="$(mktemp -d "${VERIFY_ROOT}/.tag-iso-XXXXXX")"
  trap cleanup EXIT
  GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB}" GVPN_ISO_DIR="${VERIFY_DIR}/iso" \
    "${REPO_ROOT}/tools/pull-iso.sh" "${version}" >/dev/null
}

# The ID of the image a published ISO embeds, empty when it records none.
published_image() {
  oras manifest fetch "$1" | jq -r --arg key "${IMAGE_ID_ANNOTATION}" '.annotations[$key] // empty'
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --no-channel) MOVE_CHANNEL=0 ;;
      --tag-only) TAG_ONLY=1 ;;
      -h|--help) usage ;;
      --*) die "unknown option '$1'" ;;
      *)
        [[ -z "${VERSION_ARG}" ]] || die "usage: tools/publish-iso.sh [--no-channel] [VERSION]"
        VERSION_ARG="$1"
        ;;
    esac
    shift
  done
}

# Move the channel tag to an already pushed artifact. The digest is the one the
# publish step signed; this only adds a tag.
move_channel() {
  local from_tag="$1" to_tag="$2" expected="$3" moved_digest
  oras tag "${REPO}:${from_tag}" "${to_tag}" >/dev/null
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
    [[ -n "${VERSION_ARG}" ]] || die "--tag-only needs VERSION"
    version="${VERSION_ARG}"
  else
    version="$(resolved_version)"
  fi
  [[ "${version}" =~ ${VERSION_RE} ]] || die "unusable ISO version '${version}'"
  [[ "${version}" != *-dirty ]] || die "the ISO was built from uncommitted source (${version}); commit and rebuild it before publishing"
  tag="iso-${version}"
  channel_tag="iso-${CHANNEL}"
  (( ${#tag} <= 128 && ${#channel_tag} <= 128 )) || die "version '${version}' makes an OCI tag longer than 128 characters"

  if (( TAG_ONLY )); then
    pushed_digest="$(remote_digest "${REPO}:${tag}")" \
      || die "${REPO}:${tag} is not published"
    verify_published "${version}" \
      || die "${REPO}:${tag} does not verify against ${GVPN_COSIGN_PUB}; ${channel_tag} not moved"
    move_channel "${tag}" "${channel_tag}" "${pushed_digest}"
    echo "${REPO}:${channel_tag} now points at ${pushed_digest} (${REPO}:${tag})"
    return 0
  fi

  if tag_published "${version}"; then
    if (( MOVE_CHANNEL )); then
      die "${REPO}:${tag} is already published; publish a new version instead"
    fi
    # A version names one build. A local ISO that embeds another image than
    # the published one comes from a rebuild, whose image must not be pushed
    # under this version either: stop here, before the image is.
    if [[ -f "${ISO}.target" ]]; then
      image="$(sed -n 's/^image=//p' "${ISO}.target")"
      published="$(published_image "${REPO}:${tag}")"
      [[ -n "${image}" && "${image}" == "${published}" ]] \
        || die "${REPO}:${tag} is already published from another build of ${version} (image ${published:-not recorded}, this build ${image:-not recorded}); commit, rebuild, then publish"
    fi
    echo "${REPO}:${tag} is already published; leaving it unchanged"
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
    move_channel "${tag}" "${channel_tag}" "${pushed_digest}"
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
