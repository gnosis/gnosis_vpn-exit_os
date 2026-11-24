#!/usr/bin/env bash
# Move the hoprd v5 pin of image/versions.env to a release.
#
#   tools/bump-hoprd.sh VERSION
#
# HOPRD_VERSION, the HOPRD_IMAGE tag and digest, HOPRD_SHA256 and
# HOPRD_CFG_SHA256 move together, as tools/check-pins.sh asks. Taken the way
# the earlier bumps were:
#
#   - the digest is the one behind the VERSION tag, resolved for linux/amd64,
#     the appliances' platform (for a multi-arch tag, the index's);
#   - the hashes are those of /bin/hoprd and /bin/hoprd-cfg in that image, with
#     the symlinks into the Nix store followed, which is what the Containerfile
#     copies out of it.
#
# Nothing is written before all three values are known. Review the diff and
# open a PR: pins move by PR only (the bump-hoprd workflow does both).
#
# Needs network, skopeo and a container engine: ENGINE selects docker or
# podman, otherwise docker is used when present. SKOPEO selects the skopeo
# binary, so tests can put mocks on PATH.
set -euo pipefail

# shellcheck source=SCRIPTDIR/check-pins.sh
source "$(dirname "${BASH_SOURCE[0]}")/check-pins.sh"

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'
VERSIONS_FILE="image/versions.env"

die() {
  echo "$*" >&2
  exit 1
}

pick_engine() {
  local engine="${ENGINE:-}"
  if [[ -z "${engine}" ]]; then
    if command -v docker >/dev/null; then
      engine=docker
    elif command -v podman >/dev/null; then
      engine=podman
    else
      die "need docker or podman on PATH to hash the hoprd binaries"
    fi
  fi
  printf '%s\n' "${engine}"
}

# image_digest TAGGED_REFERENCE
image_digest() {
  local digest
  digest="$("${SKOPEO}" inspect --override-os linux --override-arch amd64 --no-tags \
    --format '{{.Digest}}' "docker://$1")" || die "cannot resolve $1"
  [[ "${digest}" =~ ${DIGEST_RE} ]] || die "$1 resolved to '${digest}', not a digest"
  printf '%s\n' "${digest}"
}

# binary_hashes IMAGE_AT_DIGEST: the sha256 of hoprd, then of hoprd-cfg.
binary_hashes() {
  local image="$1" engine workdir cid binary
  engine="$(pick_engine)"
  workdir="$(mktemp -d)"
  cid="$("${engine}" create --platform linux/amd64 "${image}")" || die "cannot create a container of ${image}"
  # The paths are inside the container: /bin/hoprd is a symlink into the Nix
  # store. `docker cp -L` follows it; podman's cp does by default and has no -L.
  for binary in hoprd hoprd-cfg; do
    if [[ "${engine}" == docker ]]; then
      "${engine}" cp -L "${cid}:/bin/${binary}" "${workdir}/${binary}" >/dev/null || { "${engine}" rm -f "${cid}" >/dev/null; die "cannot copy /bin/${binary} out of ${image}"; }
    else
      "${engine}" cp "${cid}:/bin/${binary}" "${workdir}/${binary}" >/dev/null || { "${engine}" rm -f "${cid}" >/dev/null; die "cannot copy /bin/${binary} out of ${image}"; }
    fi
    if [[ -L "${workdir}/${binary}" || ! -s "${workdir}/${binary}" ]]; then
      "${engine}" rm -f "${cid}" >/dev/null
      die "/bin/${binary} of ${image} did not come out as a regular file"
    fi
  done
  "${engine}" rm -f "${cid}" >/dev/null
  sha256sum "${workdir}/hoprd" "${workdir}/hoprd-cfg" | cut -d' ' -f1
  rm -rf "${workdir}"
}

# set_var VARIABLE VALUE: rewrite only VARIABLE's line of the versions file.
set_var() {
  sed -i -E "s|^($1=).*\$|\\1$2|" "${REPO_ROOT}/${VERSIONS_FILE}"
}

bump_main() {
  local version="${1:-}" file="${REPO_ROOT}/${VERSIONS_FILE}" current image name digest hashes hoprd_sha cfg_sha
  [[ -n "${version}" ]] || die "usage: tools/bump-hoprd.sh VERSION"
  [[ "${version}" =~ ${VERSION_RE} ]] || die "'${version}' is not a hoprd version (5.0.6)"

  current="$(pin_value "${file}" HOPRD_VERSION)"
  image="$(pin_value "${file}" HOPRD_IMAGE)"
  [[ -n "${current}" && -n "${image}" ]] || die "${VERSIONS_FILE} has no HOPRD_VERSION or HOPRD_IMAGE"
  if [[ "${current}" == "${version}" ]]; then
    echo "current ${VERSIONS_FILE}: HOPRD_VERSION ${current}"
    return 0
  fi

  # The repository of the image stays: drop the tag and the digest.
  name="${image%@*}"
  [[ "${name##*/}" == *:* ]] && name="${name%:*}"

  digest="$(image_digest "${name}:${version}")" || exit 1
  hashes="$(binary_hashes "${name}@${digest}")" || exit 1
  hoprd_sha="$(sed -n 1p <<<"${hashes}")"
  cfg_sha="$(sed -n 2p <<<"${hashes}")"

  set_var HOPRD_VERSION "${version}"
  set_var HOPRD_IMAGE "${name}:${version}@${digest}"
  set_var HOPRD_SHA256 "${hoprd_sha}"
  set_var HOPRD_CFG_SHA256 "${cfg_sha}"
  echo "updated ${VERSIONS_FILE}: HOPRD_VERSION ${current} -> ${version}"
  echo "  HOPRD_IMAGE=${name}:${version}@${digest}"
  echo "  HOPRD_SHA256=${hoprd_sha}"
  echo "  HOPRD_CFG_SHA256=${cfg_sha}"

  check_pin "${VERSIONS_FILE}" HOPRD_IMAGE "the tag was not published for this digest"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bump_main "$@"
fi
