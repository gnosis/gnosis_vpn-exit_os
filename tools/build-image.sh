#!/usr/bin/env bash
# Build the OS image with the pins from image/versions.env.
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
    GVPN_SERVER_VERSION GVPN_SERVER_SHA256 NETDATA_VERSION GVPN_IMAGE_REPO; do
  build_args+=(--build-arg "${var}=${!var}")
done
# A build arg is one line, so the key travels base64-encoded.
build_args+=(--build-arg "GVPN_COSIGN_PUB_B64=${GVPN_COSIGN_PUB_B64}")

podman build --network=host --pull=missing \
  "${build_args[@]}" --build-arg "GVPN_IMAGE_VERSION=${version}" \
  -f image/Containerfile -t "${tag}" .
echo "built ${tag} (${version})"
