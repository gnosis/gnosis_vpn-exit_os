#!/usr/bin/env bash
# Turn a built image into an installer ISO or a qcow2 disk with
# bootc-image-builder. Runs inside tools/builder.sh (rootful podman).
#
#   tools/build-disk.sh iso|qcow2 CONFIG_FILE [CHANNEL]
#
# The image is tagged with the registry repository and CHANNEL (default
# canary) first, so the installed system tracks that tag for updates.
# CONFIG_FILE is the bib config rendered on the host by
# tools/render-bib-config.sh (a path inside the repo).
set -euo pipefail

# Sourced before the change of directory: the path resolves against the caller's
# working directory when the script was started through a relative path.
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=SCRIPTDIR/../image/versions.env
source image/versions.env

BIB_IMAGE="quay.io/centos-bootc/bootc-image-builder@sha256:4d8a0d9d173a9f450ff42d70777e1e0a6681a68f5c0f5084b65222eceb1f4d05"
kind="${1:?usage: build-disk.sh iso|qcow2 CONFIG_FILE [CHANNEL]}"
config="${2:?usage: build-disk.sh iso|qcow2 CONFIG_FILE [CHANNEL]}"
channel="${3:-canary}"
# The installed device tracks this tag for updates, so only a channel that
# exists can be named: anything else installs a device that never updates.
[[ "${channel}" =~ ${GVPN_CHANNEL_RE} ]] || {
  echo "invalid channel '${channel}': the installed device tracks canary or stable" >&2
  exit 64
}
source_tag="${SOURCE_TAG:-localhost/gvpn-exit-os:dev}"
target="${GVPN_IMAGE_REPO:?Set GVPN_IMAGE_REPO to the repository used to build the image}:${channel}"

case "${kind}" in
  iso) bib_type=anaconda-iso ;;
  qcow2) bib_type=qcow2 ;;
  *) echo "unknown kind ${kind}" >&2; exit 64 ;;
esac

out="output/${kind}"
mkdir -p "${out}"

# An installer ISO gets two sidecars: install.iso.version, the version label
# of the image it embeds, and install.iso.target, what the rendered kickstart
# does (disk, enrollment, access) plus the embedded image's ID and the ISO's
# sha256. tools/publish-iso.sh trusts them, so they are removed before the
# build: a build that stops early never leaves an ISO beside the description
# of an earlier one.
if [[ "${kind}" == iso ]]; then
  find "${out}" \( -name '*.iso.version' -o -name '*.iso.target' \) -delete
  read -r image_id image_version <<< "$(podman image inspect \
    --format '{{.Id}} {{index .Labels "org.opencontainers.image.version"}}' "${source_tag}")"
  [[ -n "${image_id}" && -n "${image_version}" ]] || {
    echo "image ${source_tag} has no version label; build it with: just build" >&2
    exit 1
  }
fi
# bootc-image-builder writes manifest-*.json next to the disk image. It embeds
# the kickstart the disk was built with, enrollment private key included, at
# mode 0644: remove it after the run, and after a failed run too.
trap 'rm -f "${out}"/manifest-*.json' EXIT

podman tag "${source_tag}" "${target}"
podman run --rm --privileged --pull=missing \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "${PWD}/${config}:/config.toml:ro" \
  -v "${PWD}/${out}:/output" \
  "${BIB_IMAGE}" \
  --type "${bib_type}" --rootfs xfs --config /config.toml --use-librepo=True \
  "${target}"

# Rendered with the bastion inputs, the kickstart writes the enrollment private
# key, and the ISO carries it: bootc-image-builder writes it 0644, so leave it
# readable by its owner only.
if [[ "${kind}" == iso ]] && grep -q '/etc/gvpn-exit/enroll.key' "${config}"; then
  find "${out}" -name '*.iso' -exec chmod 0600 {} +
fi

if [[ "${kind}" == iso ]]; then
  disk=auto
  if ! grep -qx '%include /tmp/gvpn-install-disk.ks' "${config}"; then
    disk="$(sed -n 's/^ignoredisk --only-use=//p' "${config}" | head -n1)"
  fi
  enrollment=none
  if grep -q '/etc/gvpn-exit/enroll.key' "${config}"; then
    enrollment=bastion
  fi
  access=console
  if grep -q '^sshkey --username=devops ' "${config}"; then
    access=key
  fi
  while IFS= read -r iso; do
    printf '%s\n' "${image_version}" > "${iso}.version"
    printf 'disk=%s\nenrollment=%s\naccess=%s\nimage=%s\nsha256=%s\n' \
      "${disk}" "${enrollment}" "${access}" "${image_id}" \
      "$(sha256sum "${iso}" | cut -d' ' -f1)" > "${iso}.target"
  done < <(find "${out}" -type f -name '*.iso')
fi

if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  chown -R "${HOST_UID}:${HOST_GID}" output
fi
find "${out}" -name '*.iso' -o -name '*.qcow2'
