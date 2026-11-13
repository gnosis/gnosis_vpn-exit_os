#!/usr/bin/env bash
# Promote an existing published image version or digest to a channel tag (canary or stable)
# in the registry repository without re-signing.
# Verifies that the digest has a valid signature against the image-update public
# key before moving the channel tag.
#
#   tools/promote.sh VERSION CHANNEL
#
#   GVPN_IMAGE_REPO  registry repository (required)
#   GVPN_COSIGN_PUB  public half of the image-update key (default:
#                    keys/cosign.pub), the one the target devices were built with
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "${REPO_ROOT}/tools/lib.sh"
PUBLIC_KEY="${GVPN_COSIGN_PUB:-${REPO_ROOT}/keys/cosign.pub}"
DIGEST_RE='^sha256:[a-f0-9]{64}$'
REPO="${GVPN_IMAGE_REPO:?Set GVPN_IMAGE_REPO to the repository used to build the image}"

die() {
  echo "$*" >&2
  exit 1
}

remote_digest() {
  skopeo inspect --no-tags --format '{{.Digest}}' "docker://$1"
}

promote() {
  local version="${1:-}" channel="${2:-}" digest moved
  [[ -n "${version}" ]] || die "Usage: tools/promote.sh VERSION CHANNEL"
  [[ -n "${channel}" ]] || die "Usage: tools/promote.sh VERSION CHANNEL"
  [[ "${channel}" =~ ${GVPN_CHANNEL_RE} ]] \
    || die "invalid channel '${channel}': promote to canary or stable"
  require_public_key "${PUBLIC_KEY}" || exit 1

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
    || die "the signature on ${REPO}@${digest} does not verify against ${PUBLIC_KEY}; ${channel} not moved"

  # Same digest, so the signature attached to it already covers the channel.
  skopeo copy --insecure-policy --preserve-digests --remove-signatures \
    "docker://${REPO}@${digest}" "docker://${REPO}:${channel}"
  moved="$(remote_digest "${REPO}:${channel}")"
  [[ "${moved}" == "${digest}" ]] || die "${REPO}:${channel} points at ${moved}, expected ${digest}"

  echo "promoted ${REPO}:${version} (${digest}) to ${channel}"
}

main() {
  cd "${REPO_ROOT}"
  promote "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
