#!/usr/bin/env bats
# tools/build-image.sh builds the OS image, then rechunks it: the image it tags
# holds the finished filesystem split into layers by package, without the base
# image's layers, which keep the files of every package the build removes or
# upgrades. The rechunked image goes to an OCI layout, whose layers carry the
# layer plan that tools/publish.sh pushes and the next build keeps.

load helpers

SCRIPT="${REPO_ROOT}/tools/build-image.sh"
TAG="localhost/gvpn-exit-os:test"

setup() {
  setup_sandbox
  export GVPN_IMAGE_REPO=registry.example.org/fleet/gvpn-exit-os
  export GVPN_IMAGE_VERSION=v1.2.3
  export GVPN_COSIGN_PUB_B64=cHVibGljIGtleQ
  export GVPN_IMAGE_LAYOUT="${SANDBOX}/image"
  unset GVPN_PREVIOUS_BUILD
  mock_cmd podman
  mock_cmd chown
}

teardown() {
  teardown_sandbox
}

# The line number of the first recorded call matching the extended regex $1.
call_line() {
  grep -nE "$1" "${MOCK_LOG}" | head -1 | cut -d: -f1
}

@test "the build is rechunked into an OCI layout and loaded as the tag it names, then the unchunked build is removed" {
  # A layout left by an earlier build never mixes with this one.
  mkdir -p "${GVPN_IMAGE_LAYOUT}/blobs/sha256"
  touch "${GVPN_IMAGE_LAYOUT}/blobs/sha256/earlier"
  run env HOST_UID=1000 HOST_GID=100 "${SCRIPT}" "${TAG}"
  [ "${status}" -eq 0 ]
  local base build rechunk load remove
  base="$(sed -n 's/^FEDORA_IOT_IMAGE=//p' "${REPO_ROOT}/image/versions.env")"
  # The Containerfile's result never carries the tag that publishing and the
  # installer read: only the rechunked image does.
  [ -z "$(call_line "^podman build .* -t ${TAG}( |$)")" ]
  build="$(call_line "^podman build .* -t ${TAG}-unchunked( |$)")"
  # Rechunked by the pinned base image's own rpm-ostree, into the layout.
  rechunk="$(call_line "^podman run .*-v /var/lib/containers:/var/lib/containers -v ${GVPN_IMAGE_LAYOUT}:/layout ${base} rpm-ostree compose build-chunked-oci --bootc .*--from ${TAG}-unchunked .*--output oci:/layout:gvpn-exit-os$")"
  load="$(call_line "^podman run .* ${base} skopeo copy .*oci:/layout:gvpn-exit-os containers-storage:${TAG}$")"
  remove="$(call_line "^podman rmi .*${TAG}-unchunked$")"
  [ -n "${build}" ] && [ -n "${rechunk}" ] && [ -n "${load}" ] && [ -n "${remove}" ]
  (( build < rechunk && rechunk < load && load < remove ))
  # rpm-ostree writes into an existing, empty layout.
  [ -f "${GVPN_IMAGE_LAYOUT}/oci-layout" ]
  [ "$(jq -c .manifests "${GVPN_IMAGE_LAYOUT}/index.json")" = "[]" ]
  [ ! -e "${GVPN_IMAGE_LAYOUT}/blobs/sha256/earlier" ]
  # The host user owns it, as it owns the rest of output/.
  grep -qx "chown -R 1000:100 ${GVPN_IMAGE_LAYOUT}" "${MOCK_LOG}"
  [[ "${output}" == *"built ${TAG} (v1.2.3)"* ]]
}

@test "the layer plan of the repository's canary keeps the layout, unless GVPN_PREVIOUS_BUILD names another image or none" {
  run "${SCRIPT}" "${TAG}"
  [ "${status}" -eq 0 ]
  grep -q -- "rpm-ostree compose build-chunked-oci .*--previous-build docker://${GVPN_IMAGE_REPO}:canary " "${MOCK_LOG}"

  : > "${MOCK_LOG}"
  run env GVPN_PREVIOUS_BUILD=containers-storage:localhost/earlier "${SCRIPT}" "${TAG}"
  [ "${status}" -eq 0 ]
  grep -q -- "rpm-ostree compose build-chunked-oci .*--previous-build containers-storage:localhost/earlier " "${MOCK_LOG}"

  # Empty: a build without the registry, such as one with no network access to it.
  : > "${MOCK_LOG}"
  run env GVPN_PREVIOUS_BUILD= "${SCRIPT}" "${TAG}"
  [ "${status}" -eq 0 ]
  grep -q 'rpm-ostree compose build-chunked-oci' "${MOCK_LOG}"
  run grep -q -- '--previous-build' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "a failed rechunk fails the build and names the way to build without the registry" {
  mock_cmd podman '[[ "$1" != run ]]'
  run "${SCRIPT}" "${TAG}"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"built ${TAG}"* ]]
  [[ "${output}" == *"docker://${GVPN_IMAGE_REPO}:canary"*"GVPN_PREVIOUS_BUILD"* ]]
}
