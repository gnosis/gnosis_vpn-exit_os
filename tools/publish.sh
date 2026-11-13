#!/usr/bin/env bash
# Publish the built image to the registry repository the devices track,
# signed with the image-update key they trust (GVPN_COSIGN_PUB). Runs on the
# host inside the devshell, with the host's registry credentials.
#
#   tools/publish.sh            push, sign, verify, move canary
#   tools/publish.sh canary     the same, named explicitly
#   tools/publish.sh --no-channel  push, sign, verify; do not move any channel
#   tools/publish.sh unsigned-probe [CHANNEL]
#                                    test only: an unsigned copy of the image
#                                    on CHANNEL (default canary) at
#                                    <repo>:unsigned-probe, which the devices
#                                    must refuse
#
# Steps: export SOURCE_TAG from the builder's storage, push it as
# <repo>:<version label> with a sigstore signature, verify that signature
# against the update public key, then point canary at the pushed digest. The
# channel only moves once the signature verifies, and a published version is
# never overwritten. `canary` is the only channel this tool moves: `stable`
# moves only by promoting a soaked canary digest (docs/publish-image.md), and
# no version tag may be re-pointed, because that would overwrite a published
# version.
#
# skopeo signs: it writes the sigstore attachment format the devices read
# (registries.d use-sigstore-attachments). cosign only verifies, against the
# public key without a transparency log, since nothing is uploaded to one.
#
#   GVPN_COSIGN_KEY              private key (default: cosign.key at the repo
#                                root; never under keys/, which is build context)
#   GVPN_COSIGN_PUB              its public half, the one the image was built
#                                with (default: keys/cosign.pub)
#   GVPN_COSIGN_PASSPHRASE_FILE  the signing key's passphrase, or an empty file
#                                for a key without one; without it skopeo asks
#                                on the terminal, so a run without one and
#                                without a terminal refuses
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "${REPO_ROOT}/tools/lib.sh"
# shellcheck source=SCRIPTDIR/../image/versions.env
source "${REPO_ROOT}/image/versions.env"

SOURCE_TAG="${SOURCE_TAG:-localhost/gvpn-exit-os:dev}"
GVPN_BUILDER="${GVPN_BUILDER:-${REPO_ROOT}/tools/builder.sh}"
GVPN_COSIGN_KEY="${GVPN_COSIGN_KEY:-${REPO_ROOT}/cosign.key}"
GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB:-${REPO_ROOT}/keys/cosign.pub}"
GVPN_COSIGN_PASSPHRASE_FILE="${GVPN_COSIGN_PASSPHRASE_FILE:-}"
# Inside the repository, which is the only writable path the builder mounts.
GVPN_PUBLISH_ARCHIVE="${GVPN_PUBLISH_ARCHIVE:-output/publish/image.oci.tar}"
PUBLIC_KEY="${GVPN_COSIGN_PUB}"
REGISTRIES_D="${REPO_ROOT}/image/rootfs/etc/containers/registries.d"
VERSION_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
REPO="${GVPN_IMAGE_REPO:?Set GVPN_IMAGE_REPO to the repository used to build the image}"
CHANNEL=canary

die() {
  echo "$*" >&2
  exit 1
}

image_version() {
  skopeo inspect "oci-archive:${GVPN_PUBLISH_ARCHIVE}" | jq -r '.Labels["org.opencontainers.image.version"] // empty'
}

remote_digest() {
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://$1"
}

# Whether $1 (repo:tag) exists. Only the registry's "manifest unknown" means it
# does not; any other lookup failure aborts, because taking it for "not
# published" could overwrite a published version.
tag_published() {
  local error
  if error="$(skopeo inspect --no-tags --format '{{.Digest}}' "docker://$1" 2>&1 >/dev/null)"; then
    return 0
  fi
  [[ "${error}" == *"manifest unknown"* ]] || die "cannot tell whether $1 is published: ${error}"
  return 1
}

publish() {
  local channel="${1:-${CHANNEL}}" version digest moved
  local move_channel=1
  local sign_args=(--sign-by-sigstore-private-key "${GVPN_COSIGN_KEY}")
  if [[ "${channel}" == "--no-channel" || "${channel}" == "push" ]]; then
    move_channel=0
  else
    [[ "${channel}" != stable ]] || die "stable moves only by promotion of a soaked canary digest, never by publishing"
    [[ "${channel}" == "${CHANNEL}" ]] || die "invalid channel '${channel}': this tool moves ${CHANNEL} only"
  fi
  [[ -r "${GVPN_COSIGN_KEY}" ]] || die "GVPN_COSIGN_KEY: no signing key at ${GVPN_COSIGN_KEY}"
  require_public_key "${PUBLIC_KEY}" || exit 1
  if [[ -n "${GVPN_COSIGN_PASSPHRASE_FILE}" ]]; then
    sign_args+=(--sign-passphrase-file "${GVPN_COSIGN_PASSPHRASE_FILE}")
  elif [[ ! -t 0 ]]; then
    # skopeo asks for the passphrase on the terminal when it is given none, so
    # a run without a terminal (CI) would stop inside the push instead.
    die "GVPN_COSIGN_PASSPHRASE_FILE is not set and stdin is not a terminal: set it to a file holding the signing key's passphrase, or to an empty file for a key without one"
  fi

  mkdir -p "$(dirname "${GVPN_PUBLISH_ARCHIVE}")"
  trap 'rm -f "${GVPN_PUBLISH_ARCHIVE}" "${GVPN_PUBLISH_ARCHIVE}.digest"' EXIT
  rm -f "${GVPN_PUBLISH_ARCHIVE}"
  "${GVPN_BUILDER}" podman save --format oci-archive -o "${GVPN_PUBLISH_ARCHIVE}" "${SOURCE_TAG}"

  version="$(image_version)"
  [[ "${version}" =~ ${VERSION_RE} ]] || die "image ${SOURCE_TAG} has no usable version label (got '${version}')"
  # An uncommitted build is not a release: the label would not identify source
  # anyone can rebuild (docs/publish-image.md).
  [[ "${version}" != *-dirty ]] || die "image ${SOURCE_TAG} was built from uncommitted source (${version}); commit, rebuild, then publish"
  if tag_published "${REPO}:${version}"; then
    die "${REPO}:${version} is already published; commit or tag, rebuild, then publish"
  fi

  # --insecure-policy: the source is our own archive; what counts is the
  # signature check below, against the key the devices hold.
  skopeo copy --insecure-policy --registries.d "${REGISTRIES_D}" "${sign_args[@]}" \
    --digestfile "${GVPN_PUBLISH_ARCHIVE}.digest" \
    "oci-archive:${GVPN_PUBLISH_ARCHIVE}" "docker://${REPO}:${version}"
  digest="$(< "${GVPN_PUBLISH_ARCHIVE}.digest")"

  cosign verify --key "${PUBLIC_KEY}" --insecure-ignore-tlog=true "${REPO}@${digest}" >/dev/null \
    || die "the signature on ${REPO}@${digest} does not verify against ${PUBLIC_KEY} (wrong GVPN_COSIGN_KEY or GVPN_COSIGN_PUB?); ${channel} not moved"

  if [[ "${move_channel}" -eq 1 ]]; then
    # Same digest, so the signature attached to it already covers the channel.
    skopeo copy --insecure-policy --preserve-digests --remove-signatures \
      "docker://${REPO}@${digest}" "docker://${REPO}:${channel}"
    moved="$(remote_digest "${REPO}:${channel}")"
    [[ "${moved}" == "${digest}" ]] || die "${REPO}:${channel} points at ${moved}, expected ${digest}"

    echo "published ${REPO}:${version} (${digest}), signed; ${channel} points at it"
  else
    echo "pushed ${REPO}:${version} (${digest}), signed; no channel tag moved"
  fi
}

# An unsigned image with a different digest: the v2s2 manifest of the channel
# image the test device tracks, which the device must refuse. The channel is an
# argument so a device on `stable` is probed with the image it tracks.
unsigned_probe() {
  local channel="${1:-${CHANNEL}}"
  [[ "${channel}" =~ ${VERSION_RE} ]] || die "invalid channel '${channel}'"
  skopeo copy --insecure-policy --remove-signatures --format v2s2 \
    "docker://${REPO}:${channel}" "docker://${REPO}:unsigned-probe"
  echo "unsigned probe at ${REPO}:unsigned-probe (copy of ${REPO}:${channel})"
}

main() {
  # Relative paths mean the same file on the host and in the builder (/src).
  cd "${REPO_ROOT}"
  case "${1:-}" in
    unsigned-probe) shift; unsigned_probe "$@" ;;
    *) publish "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
