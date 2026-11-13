#!/usr/bin/env bash
# Run a command where rootful podman is available: bootc image builds and
# bootc-image-builder need it. As root with podman installed the command runs
# directly; otherwise it runs in a privileged podman container driven by
# docker, with container storage in a named volume so images persist between
# calls. Inside that container the repository is mounted read-only at /src:
# only output/ is writable, which is all any recipe needs (disk images,
# publish archives).
#
#   tools/builder.sh podman build ...
set -euo pipefail

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The builder is pinned by tag and digest: the tag says which Podman release
# this is, the digest says which manifest list, so neither a re-pushed tag nor a
# different image behind the same tag can change the toolchain of a build. The
# digest is the tag's own, an index for a multi-arch image, so the host's
# platform is still picked when the container runs. Podman's `-immutable` tags
# are pushed once and never overwritten (quay.io garbage-collects the manifests
# behind the daily-moving version tags, so a pinned digest of those eventually
# stops resolving). Bump both by taking the newest vX.Y.Z-immutable from
# https://quay.io/repository/podman/stable?tab=tags (`just update-pins` does).
PODMAN_IMAGE="quay.io/podman/stable:v5.8.9-immutable@sha256:0ccbc4e7f79f9c33e7fc959be59f714abbc0f4c9cffbe14f5bceff537a014738"
STORAGE_VOLUME="gvpn-exit-os-storage"

if [[ "$(id -u)" -eq 0 ]] && command -v podman >/dev/null; then
  cd "${REPO_ROOT}"
  exec "$@"
fi

if ! command -v docker >/dev/null; then
  echo "need either root with podman, or docker" >&2
  exit 1
fi

tty_flags=()
[[ -t 0 && -t 1 ]] && tty_flags=(-it)
# Mounted read-write on top of the read-only repository.
mkdir -p "${REPO_ROOT}/output"

# The image-update public key may live anywhere on this host; pass its content
# into the container, which only mounts the repository.
env_args=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)"
  -e GVPN_IMAGE_VERSION -e SOURCE_TAG -e GVPN_IMAGE_REPO -e GVPN_COSIGN_PUB_B64)
if [[ -z "${GVPN_COSIGN_PUB_B64:-}" && -n "${GVPN_COSIGN_PUB:-}" ]]; then
  require_public_key "${GVPN_COSIGN_PUB}" || exit 1
  env_args+=(-e GVPN_COSIGN_PUB_B64="$(base64_one_line "${GVPN_COSIGN_PUB}")")
fi

exec docker run --rm "${tty_flags[@]}" --privileged --network=host \
  -v "${STORAGE_VOLUME}:/var/lib/containers" \
  -v /dev:/dev \
  -v "${REPO_ROOT}:/src:ro" \
  -v "${REPO_ROOT}/output:/src/output" -w /src \
  "${env_args[@]}" \
  "${PODMAN_IMAGE}" "$@"
