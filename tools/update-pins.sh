#!/usr/bin/env bash
# Move every pinned image reference to the newest one its target offers.
#
#   tools/update-pins.sh
#
# The pins are the ones tools/check-pins.sh verifies:
#
#   FEDORA_IOT_IMAGE  the digest behind its tag (quay.io/fedora/fedora-iot:44);
#                     the Fedora major version only moves by editing the tag
#   HOPRD_IMAGE is checked by check-pins.sh but not moved here: its binary
#   sha256 pins (HOPRD_SHA256, HOPRD_CFG_SHA256) must move in the same commit,
#   so bump the tag, digest and both hashes together by hand.
#   BIB_IMAGE         the digest behind bootc-image-builder:latest
#   PODMAN_IMAGE      the newest vX.Y.Z-immutable tag of quay.io/podman/stable
#                     and the digest behind it
#
# Digests are resolved for linux/amd64, the appliances' platform, which also
# makes the lookup work on a Darwin host; for a multi-arch tag the digest is
# the index's. Every new reference is resolved before any file is written, so
# a registry error leaves all pins as they were. The result is then checked
# with tools/check-pins.sh. Review the diff and open a PR: pins move by PR only.
#
# Needs network. SKOPEO selects the binary, so tests can put a mock on PATH.
set -euo pipefail

# shellcheck source=SCRIPTDIR/check-pins.sh
source "$(dirname "${BASH_SOURCE[0]}")/check-pins.sh"

DIGEST_RE='^sha256:[0-9a-f]{64}$'
PODMAN_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+-immutable$'

die() {
  echo "$*" >&2
  exit 1
}

# latest_digest TAGGED_REFERENCE
latest_digest() {
  local digest
  digest="$("${SKOPEO}" inspect --override-os linux --override-arch amd64 --no-tags \
    --format '{{.Digest}}' "docker://$1")" || die "cannot resolve $1"
  [[ "${digest}" =~ ${DIGEST_RE} ]] || die "$1 resolved to '${digest}', not a digest"
  printf '%s\n' "${digest}"
}

# digest_pin VALUE DEFAULT_TAG
# VALUE moved to the newest digest of the tag it carries
# (fedora-iot:44@sha256:...), or of DEFAULT_TAG when it carries none.
digest_pin() {
  local value="$1" name target digest
  name="${value%@*}"
  target="${name}"
  [[ "${name##*/}" == *:* ]] || target="${name}:$2"
  digest="$(latest_digest "${target}")" || exit 1
  printf '%s@%s\n' "${name}" "${digest}"
}

latest_podman() {
  local ref="${1%@*}" name tags tag digest
  name="${ref%:*}"
  tags="$("${SKOPEO}" list-tags "docker://${name}")" || die "cannot list the tags of ${name}"
  tag="$(jq -r '.Tags[]' <<<"${tags}" | grep -E "${PODMAN_TAG_RE}" | sort -V | tail -n1)" || true
  [[ -n "${tag}" ]] || die "${name} has no vX.Y.Z-immutable tag"
  # Resolve the tag before it is written: a registry that lists a tag it can no
  # longer serve must stop the run with every pin untouched. The digest is the
  # tag's own (an index for a multi-arch image), so the builder container still
  # runs the host's platform.
  digest="$(latest_digest "${name}:${tag}")" || exit 1
  printf '%s:%s@%s\n' "${name}" "${tag}" "${digest}"
}

# set_pin FILE VARIABLE VALUE: rewrite only VARIABLE's line, keeping its quotes.
set_pin() {
  sed -i -E "s|^($2=)(\"?)[^\"]*(\"?)\$|\\1\\2$3\\3|" "${REPO_ROOT}/$1"
}

update_main() {
  local fedora bib podman new_fedora new_bib new_podman update file variable old new
  fedora="$(pin_value "${REPO_ROOT}/image/versions.env" FEDORA_IOT_IMAGE)"
  bib="$(pin_value "${REPO_ROOT}/tools/build-disk.sh" BIB_IMAGE)"
  podman="$(pin_value "${REPO_ROOT}/tools/builder.sh" PODMAN_IMAGE)"
  # The Fedora major version is a decision, not an update: follow its tag.
  [[ "${fedora%@*}" == */*:* ]] || die "FEDORA_IOT_IMAGE carries no tag to follow: ${fedora}"

  # set -e does not reach into $(...), so every lookup stops the run itself.
  new_fedora="$(digest_pin "${fedora}" "")" || exit 1
  new_bib="$(digest_pin "${bib}" latest)" || exit 1
  new_podman="$(latest_podman "${podman}")" || exit 1

  for update in "image/versions.env|FEDORA_IOT_IMAGE|${fedora}|${new_fedora}" \
    "tools/build-disk.sh|BIB_IMAGE|${bib}|${new_bib}" \
    "tools/builder.sh|PODMAN_IMAGE|${podman}|${new_podman}"; do
    IFS='|' read -r file variable old new <<<"${update}"
    if [[ "${old}" == "${new}" ]]; then
      echo "current ${file}: ${variable} ${old}"
      continue
    fi
    set_pin "${file}" "${variable}" "${new}"
    echo "updated ${file}: ${variable} ${old} -> ${new}"
  done
  main
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  update_main "$@"
fi
