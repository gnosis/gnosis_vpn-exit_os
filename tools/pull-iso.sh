#!/usr/bin/env bash
# Pull a published installer ISO, verify its signature and checksums, and
# print the local ISO path. The signature is on the checksum file
# install.iso.sha256, which lists the ISO, its version and its target: all
# three are checked against it, so nothing read here is outside the signature.
# A tag is not: under a channel or a version tag a registry can still serve
# another ISO that was published with the same key. A channel tag then fails
# only on the channel the artifact reports, a version tag also on the version.
# The artifact is the one tools/publish-iso.sh pushes to GVPN_ISO_REPO, under
# VERSION-CHANNEL and the channel: an ISO installs a device that follows one
# channel for its updates, the one in its tag. The same ISO installs hardware
# from a USB stick or an Incus VM, so it must detect its install disk, carry
# no bastion enrollment and be configured on the console.
#
#   tools/pull-iso.sh canary|stable|VERSION-CHANNEL[@DIGEST]
#
# With @DIGEST, that manifest is pulled instead of the tag, and is still
# checked against the reference before it: tools/publish-iso.sh verifies the
# digest it is about to tag this way.
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
  local ref="${1:-}" pull_ref work iso version channel disk listed
  [[ -n "${ref}" ]] || die "usage: tools/pull-iso.sh canary|stable|VERSION-CHANNEL[@DIGEST]"
  pull_ref="${REPO}:${ref%%@*}"
  if [[ "${ref}" == *@* ]]; then
    [[ "${ref#*@}" =~ ^sha256:[a-f0-9]{64}$ ]] || die "invalid digest '${ref#*@}': give sha256:<64 hex digits>"
    pull_ref="${REPO}@${ref#*@}"
    ref="${ref%%@*}"
  fi
  [[ "${ref}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid version or channel '${ref}'"
  # Every published ISO is tagged with the channel its devices follow.
  [[ "${ref}" =~ ${GVPN_CHANNEL_RE} || "${ref}" =~ -(canary|stable)$ ]] \
    || die "'${ref}' names no channel: pull canary, stable or a VERSION-CHANNEL such as ${ref}-canary"
  [[ -n "${OUT}" && "${OUT}" != "/" ]] || die "GVPN_ISO_DIR must name a directory, got '${OUT}'"
  require_public_key "${GVPN_COSIGN_PUB}" || exit 1

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
  oras pull "${pull_ref}" -o "${work}" >/dev/null \
    || die "cannot pull ${pull_ref}; is the version published?"
  iso="${work}/install.iso"
  [[ -s "${iso}" ]] || die "${pull_ref} contains no install.iso"
  [[ -s "${iso}.sha256" && -s "${iso}.sha256.sigstore.json" \
      && -s "${iso}.version" && -s "${iso}.target" ]] \
    || die "${pull_ref} is missing its checksum, signature, version or target file"
  cosign verify-blob --key "${GVPN_COSIGN_PUB}" --bundle "${iso}.sha256.sigstore.json" \
    --insecure-ignore-tlog=true "${iso}.sha256" >/dev/null \
    || die "signature of ${iso}.sha256 does not verify against ${GVPN_COSIGN_PUB}"
  # The signed checksum file has to list the sidecars too: one it leaves out
  # would be read below without being verified.
  listed="$(awk '{ print $2 }' "${iso}.sha256" | sort | tr '\n' ' ')"
  [[ "${listed}" == "install.iso install.iso.target install.iso.version " ]] \
    || die "the signed checksum file of ${pull_ref} does not cover the ISO, its version and its target"
  ( cd "${work}" && sha256sum -c --strict install.iso.sha256 >/dev/null 2>&1 ) \
    || die "checksum mismatch for ${iso} or its sidecars"

  disk="$(sed -n 's/^disk=//p' "${iso}.target")"
  grep -qx 'disk=auto' "${iso}.target" \
    || die "${pull_ref} pins install disk ${disk:-(none recorded)}; a published ISO must detect its disk"
  grep -qx 'enrollment=none' "${iso}.target" \
    || die "${pull_ref} carries bastion enrollment data; a published ISO must be unmanaged"
  grep -qx 'access=console' "${iso}.target" \
    || die "${pull_ref} carries an installer SSH key; a published ISO must be console-configured"
  version="$(< "${iso}.version")"
  channel="$(sed -n 's/^channel=//p' "${iso}.target")"
  # An ISO published before the target recorded the channel names none.
  [[ -n "${channel}" ]] \
    || die "${pull_ref} records no channel its devices follow: it was published before ISOs named theirs; promote its version to the channel again to publish one that does"
  [[ "${channel}" =~ ${GVPN_CHANNEL_RE} ]] \
    || die "${pull_ref} records channel '${channel}': a device follows canary or stable"
  if [[ "${ref}" =~ ${GVPN_CHANNEL_RE} ]]; then
    [[ "${channel}" == "${ref}" ]] \
      || die "${pull_ref} installs a device that follows ${channel}, not ${ref}"
  else
    [[ "${version}-${channel}" == "${ref}" ]] \
      || die "${pull_ref} reports version ${version} on ${channel}, expected ${ref}"
  fi

  rm -rf "${OUT}"
  mv "${work}" "${OUT}"
  trap - EXIT
  printf '%s\n' "${OUT}/install.iso"
}

main "$@"
