#!/usr/bin/env bash
# Pull a published installer ISO, verify its signature and checksums, and
# print the local ISO path. The signature is on the checksum file
# install.iso.sha256, which lists the ISO, its version and its target: all
# three are checked against it, so nothing read here is outside the signature.
# A tag is not: under `canary`, or a version tag, a registry can still serve
# another ISO that was published with the same key, and only a version tag
# then fails, on the version the artifact reports. The artifact is the one
# tools/publish-iso.sh pushes to GVPN_ISO_REPO: a version or the canary tag. The same ISO
# installs hardware from a USB stick or an Incus VM, so it must detect its
# install disk, carry no bastion enrollment and be configured on the console.
#
#   tools/pull-iso.sh VERSION|canary
#
#   GVPN_ISO_REPO      registry repository of the ISO, required, and not
#                      GVPN_IMAGE_REPO
#   GVPN_COSIGN_PUB    public half of the image-update key (default:
#                      keys/cosign.pub)
#   GVPN_ISO_DIR       local directory (default: output/published-iso)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
source "${REPO_ROOT}/tools/lib.sh"

REPO="$(iso_repo)" || exit 1
GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB:-${REPO_ROOT}/keys/cosign.pub}"
OUT="${GVPN_ISO_DIR:-${REPO_ROOT}/output/published-iso}"

die() {
  echo "$*" >&2
  exit 1
}

main() {
  local ref="${1:-}" tag work iso version disk listed
  [[ -n "${ref}" ]] || die "usage: tools/pull-iso.sh VERSION|canary"
  [[ "${ref}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid version or channel '${ref}'"
  [[ -n "${OUT}" && "${OUT}" != "/" ]] || die "GVPN_ISO_DIR must name a directory, got '${OUT}'"
  require_public_key "${GVPN_COSIGN_PUB}" || exit 1
  tag="${ref}"

  if [[ -e "${OUT}" && ! -d "${OUT}" ]]; then
    die "GVPN_ISO_DIR is not a directory: ${OUT}"
  fi
  if [[ -d "${OUT}" ]]; then
    shopt -s nullglob dotglob
    local entry
    for entry in "${OUT}"/*; do
      case "$(basename "${entry}")" in
        install.iso*) ;;
        *) die "refusing to replace ${OUT}; it holds $(basename "${entry}")" ;;
      esac
    done
    shopt -u nullglob dotglob
  fi

  # Pull and verify in a temporary sibling first, so a failed pull or
  # signature never replaces an ISO that was already good.
  mkdir -p "$(dirname "${OUT}")"
  work="$(mktemp -d "${OUT}.XXXXXX")"
  trap 'rm -rf "${work}"' EXIT
  oras pull "${REPO}:${tag}" -o "${work}" >/dev/null \
    || die "cannot pull ${REPO}:${tag}; is the version published?"
  iso="${work}/install.iso"
  [[ -s "${iso}" ]] || die "${REPO}:${tag} contains no install.iso"
  [[ -s "${iso}.sha256" && -s "${iso}.sha256.sigstore.json" \
      && -s "${iso}.version" && -s "${iso}.target" ]] \
    || die "${REPO}:${tag} is missing its checksum, signature, version or target file"
  cosign verify-blob --key "${GVPN_COSIGN_PUB}" --bundle "${iso}.sha256.sigstore.json" \
    --insecure-ignore-tlog=true "${iso}.sha256" >/dev/null \
    || die "signature of ${iso}.sha256 does not verify against ${GVPN_COSIGN_PUB}"
  # The signed checksum file has to list the sidecars too: one it leaves out
  # would be read below without being verified.
  listed="$(awk '{ print $2 }' "${iso}.sha256" | sort | tr '\n' ' ')"
  [[ "${listed}" == "install.iso install.iso.target install.iso.version " ]] \
    || die "the signed checksum file of ${REPO}:${tag} does not cover the ISO, its version and its target"
  ( cd "${work}" && sha256sum -c --strict install.iso.sha256 >/dev/null 2>&1 ) \
    || die "checksum mismatch for ${iso} or its sidecars"

  disk="$(sed -n 's/^disk=//p' "${iso}.target")"
  grep -qx 'disk=auto' "${iso}.target" \
    || die "${REPO}:${tag} pins install disk ${disk:-(none recorded)}; a published ISO must detect its disk"
  grep -qx 'enrollment=none' "${iso}.target" \
    || die "${REPO}:${tag} carries bastion enrollment data; a published ISO must be unmanaged"
  grep -qx 'access=console' "${iso}.target" \
    || die "${REPO}:${tag} carries an installer SSH key; a published ISO must be console-configured"
  version="$(< "${iso}.version")"
  case "${ref}" in
    canary) ;;
    *) [[ "${version}" == "${ref}" ]] || die "${REPO}:${tag} reports version ${version}, expected ${ref}" ;;
  esac

  rm -rf "${OUT}"
  mv "${work}" "${OUT}"
  trap - EXIT
  printf '%s\n' "${OUT}/install.iso"
}

main "$@"
