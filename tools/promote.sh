#!/usr/bin/env bash
# Promote an existing published image version or digest to a channel tag (canary or stable)
# in the registry repository without re-signing.
# Verifies that the digest has a valid signature against the image-update public
# key before moving the channel tag.
#
#   tools/promote.sh VERSION CHANNEL
#   tools/promote.sh --pull VERSION
#
# --pull moves nothing in the registry: it verifies VERSION the same way and
# pulls that digest into the builder as the local image (SOURCE_TAG), so the
# installer ISO of a promotion is built from the promoted image itself.
#
#   GVPN_IMAGE_REPO  registry repository (required)
#   GVPN_COSIGN_PUB  public half of the image-update key (default:
#                    keys/cosign.pub), the one the target devices were built with
#   GVPN_BUILDER     command that runs podman (default: tools/builder.sh)
#   SOURCE_TAG       local image tag --pull writes (default:
#                    localhost/gvpn-exit-os:dev)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "${REPO_ROOT}/tools/lib.sh"
PUBLIC_KEY="${GVPN_COSIGN_PUB:-${REPO_ROOT}/keys/cosign.pub}"
DIGEST_RE='^sha256:[a-f0-9]{64}$'
REPO="${GVPN_IMAGE_REPO:?Set GVPN_IMAGE_REPO to the repository used to build the image}"
GVPN_BUILDER="${GVPN_BUILDER:-${REPO_ROOT}/tools/builder.sh}"
SOURCE_TAG="${SOURCE_TAG:-localhost/gvpn-exit-os:dev}"

die() {
  echo "$*" >&2
  exit 1
}

remote_digest() {
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://$1"
}

# verified_digest VERSION WHAT
# Print the digest of VERSION (a tag or a digest) after its signature verified
# against the image-update public key. WHAT ends the message of a failed
# verification: what did not happen because of it.
verified_digest() {
  local version="$1" what="$2" digest
  if [[ "${version}" =~ ${DIGEST_RE} ]]; then
    digest="${version}"
  else
    local out error
    if out="$(remote_digest "${REPO}:${version}" 2>/dev/null)"; then
      digest="${out}"
    else
      # Only on failure: ask again for the registry's own message.
      error="$(remote_digest "${REPO}:${version}" 2>&1 >/dev/null)" || true
      die "cannot resolve ${REPO}:${version} in registry: ${error##*$'\n'}"
    fi
  fi

  cosign verify --key "${PUBLIC_KEY}" --insecure-ignore-tlog=true "${REPO}@${digest}" >/dev/null \
    || die "the signature on ${REPO}@${digest} does not verify against ${PUBLIC_KEY}; ${what}"
  printf '%s\n' "${digest}"
}

promote() {
  local version="${1:-}" channel="${2:-}" digest moved
  [[ -n "${version}" ]] || die "Usage: tools/promote.sh VERSION CHANNEL"
  [[ -n "${channel}" ]] || die "Usage: tools/promote.sh VERSION CHANNEL"
  [[ "${channel}" =~ ${GVPN_CHANNEL_RE} ]] \
    || die "invalid channel '${channel}': promote to canary or stable"
  require_public_key "${PUBLIC_KEY}" || exit 1
  digest="$(verified_digest "${version}" "${channel} not moved")"

  # Same digest, so the signature attached to it already covers the channel.
  skopeo copy --insecure-policy --preserve-digests --remove-signatures \
    "docker://${REPO}@${digest}" "docker://${REPO}:${channel}"
  moved="$(remote_digest "${REPO}:${channel}")"
  [[ "${moved}" == "${digest}" ]] || die "${REPO}:${channel} points at ${moved}, expected ${digest}"

  echo "promoted ${REPO}:${version} (${digest}) to ${channel}"
}

pull() {
  local version="${1:-}" digest
  [[ -n "${version}" ]] || die "Usage: tools/promote.sh --pull VERSION"
  require_public_key "${PUBLIC_KEY}" || exit 1
  digest="$(verified_digest "${version}" "image not pulled")"
  # By digest: the image the builder gets is the one that verified.
  "${GVPN_BUILDER}" podman pull "${REPO}@${digest}"
  "${GVPN_BUILDER}" podman tag "${REPO}@${digest}" "${SOURCE_TAG}"
  echo "pulled ${REPO}:${version} (${digest}) as ${SOURCE_TAG}"
}

main() {
  cd "${REPO_ROOT}"
  case "${1:-}" in
    --pull) shift; pull "$@" ;;
    *) promote "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
