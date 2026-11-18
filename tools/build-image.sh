#!/usr/bin/env bash
# Build the OS image with the pins from image/versions.env, then rechunk it.
# Runs inside tools/builder.sh (rootful podman).
#
#   tools/build-image.sh [TAG]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=SCRIPTDIR/../image/versions.env
source image/versions.env
tag="${1:-localhost/gvpn-exit-os:dev}"
version="${GVPN_IMAGE_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
# HOPRD_IMAGE and HOPRD_VERSION are separate pins; a tag that does not match
# would label one version and run another.
[[ "${HOPRD_IMAGE%@*}" == *:"${HOPRD_VERSION}" ]] \
  || { echo "HOPRD_IMAGE tag does not match HOPRD_VERSION=${HOPRD_VERSION}" >&2; exit 1; }
# The public half of the key that signs image updates. It is a build input, not
# a file in the repository, because each operator has to ship devices that
# trust the key that operator can sign with. tools/builder.sh resolves it on the
# host and passes the content in, so the key may live outside the repository.
if [[ -z "${GVPN_COSIGN_PUB_B64:-}" ]]; then
  GVPN_COSIGN_PUB="${GVPN_COSIGN_PUB:-${PWD}/keys/cosign.pub}"
  require_public_key "${GVPN_COSIGN_PUB}" || exit 1
  GVPN_COSIGN_PUB_B64="$(base64_one_line "${GVPN_COSIGN_PUB}")"
fi

image/build/configure-image.sh
build_args=()
for var in FEDORA_IOT_IMAGE HOPRD_IMAGE HOPRD_VERSION HOPRD_SHA256 HOPRD_CFG_SHA256 \
    HOPRD_V4_VERSION HOPRD_V4_SHA256 HOPRD_V4_CFG_SHA256 FOUNDRY_VERSION FOUNDRY_SHA256 HOPLI_VERSION HOPLI_SHA256 \
    GVPN_SERVER_VERSION GVPN_SERVER_SHA256 NETDATA_VERSION \
    NODE_EXPORTER_VERSION NODE_EXPORTER_RELEASE NODE_EXPORTER_SRPM_SHA256 GVPN_IMAGE_REPO; do
  build_args+=(--build-arg "${var}=${!var}")
done
# A build arg is one line, so the key travels base64-encoded.
build_args+=(--build-arg "GVPN_COSIGN_PUB_B64=${GVPN_COSIGN_PUB_B64}")

podman build --network=host --pull=missing \
  "${build_args[@]}" --build-arg "GVPN_IMAGE_VERSION=${version}" \
  -f image/Containerfile -t "${tag}-unchunked" .

# Rechunk: the Containerfile's result keeps the base image's layers below its
# own, and those layers still hold every file of the packages the build removes
# or upgrades, where image scanners report them and every pull downloads them.
# rpm-ostree writes the finished filesystem as a new image instead, split into
# layers by package and keeping the build's labels, so an update downloads only
# the layers whose packages changed. rpm-ostree comes from the pinned base
# image and works on the builder's container storage.
#
# Each layer is annotated with the packages in it (ostree.components), the
# layer plan. A copy out of container storage drops the annotations, so the
# image goes to an OCI layout, which tools/publish.sh pushes, and is copied into
# the storage from there.
# rpm-ostree opens the output before writing it, so the layout has to exist.
rm -rf "${GVPN_IMAGE_LAYOUT}"
mkdir -p "${GVPN_IMAGE_LAYOUT}/blobs/sha256"
printf '{"imageLayoutVersion":"1.0.0"}\n' > "${GVPN_IMAGE_LAYOUT}/oci-layout"
printf '{"schemaVersion":2,"manifests":[]}\n' > "${GVPN_IMAGE_LAYOUT}/index.json"
layout="$(cd "${GVPN_IMAGE_LAYOUT}" && pwd)"
podman run --rm --privileged -v /var/lib/containers:/var/lib/containers -v "${layout}:/layout" \
  "${FEDORA_IOT_IMAGE}" rpm-ostree compose build-chunked-oci --bootc --format-version=2 \
  --from "${tag}-unchunked" --output "oci:/layout:${GVPN_IMAGE_LAYOUT_REF}"
podman run --rm --privileged -v /var/lib/containers:/var/lib/containers -v "${layout}:/layout:ro" \
  "${FEDORA_IOT_IMAGE}" skopeo copy --quiet "oci:/layout:${GVPN_IMAGE_LAYOUT_REF}" "containers-storage:${tag}"
# --no-prune keeps the build's cached layers for the next build.
podman rmi --no-prune "${tag}-unchunked"
if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  chown -R "${HOST_UID}:${HOST_GID}" "${GVPN_IMAGE_LAYOUT}"
fi
echo "built ${tag} (${version})"
