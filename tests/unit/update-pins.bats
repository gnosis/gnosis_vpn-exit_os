#!/usr/bin/env bats
# tools/update-pins.sh moves every pinned image reference to the newest one its
# target tag offers: the digest behind Fedora IoT's major-version tag and
# bootc-image-builder's `latest`, and Podman's newest vX.Y.Z-immutable tag with
# the digest behind it.
# It runs against a copy of the pinned files, so the real pins never move.

load helpers

NEW_FEDORA="sha256:$(printf 'f%.0s' {1..64})"
NEW_BIB="sha256:$(printf 'b%.0s' {1..64})"
NEW_PODMAN="sha256:$(printf 'c%.0s' {1..64})"

setup() {
  setup_sandbox
  REPO="${SANDBOX}/repo"
  mkdir -p "${REPO}/tools" "${REPO}/image"
  cp "${REPO_ROOT}/tools/update-pins.sh" "${REPO_ROOT}/tools/check-pins.sh" \
    "${REPO_ROOT}/tools/build-disk.sh" "${REPO_ROOT}/tools/builder.sh" "${REPO}/tools/"
  cp "${REPO_ROOT}/image/versions.env" "${REPO}/image/"
  cp -R "${REPO}" "${SANDBOX}/before"
  # A registry whose tags have moved on. v5.10.1 sorts above v5.9.0 only by
  # version, and a plain or a pre-release tag is never an immutable pin.
  mock_cmd skopeo "
    case \"\$*\" in
      *list-tags*) echo '{\"Tags\": [\"v5.8.9-immutable\", \"v5.10.1-immutable\", \"v5.9.0-immutable\", \"v6.0.0\", \"v6.0.0-rc1-immutable\", \"latest\"]}' ;;
      *inspect*--format*fedora-iot:44) echo '${NEW_FEDORA}' ;;
      *inspect*--format*bootc-image-builder:latest) echo '${NEW_BIB}' ;;
      *inspect*--format*quay.io/podman/stable:*) echo '${NEW_PODMAN}' ;;
      *inspect*--raw*) exit 0 ;;
      *) echo \"unexpected: \$*\" >&2; exit 1 ;;
    esac"
}

teardown() {
  teardown_sandbox
}

pin() {
  grep "^$2=" "${REPO}/$1"
}

@test "every pin moves to the newest reference of its target" {
  run "${REPO}/tools/update-pins.sh"
  [ "${status}" -eq 0 ]
  [ "$(pin image/versions.env FEDORA_IOT_IMAGE)" = "FEDORA_IOT_IMAGE=quay.io/fedora/fedora-iot:44@${NEW_FEDORA}" ]
  [ "$(pin tools/build-disk.sh BIB_IMAGE)" = "BIB_IMAGE=\"quay.io/centos-bootc/bootc-image-builder@${NEW_BIB}\"" ]
  [ "$(pin tools/builder.sh PODMAN_IMAGE)" = "PODMAN_IMAGE=\"quay.io/podman/stable:v5.10.1-immutable@${NEW_PODMAN}\"" ]
}

@test "digests are resolved for the platform the appliances run" {
  "${REPO}/tools/update-pins.sh"
  grep -q -- '--override-os linux --override-arch amd64 .*docker://quay.io/fedora/fedora-iot:44$' "${MOCK_LOG}"
}

@test "nothing but the pinned lines changes" {
  "${REPO}/tools/update-pins.sh"
  [ "$(diff -r "${SANDBOX}/before" "${REPO}" | grep -c '^>')" -eq 3 ]
}

@test "the updated pins are checked against the registry" {
  run "${REPO}/tools/update-pins.sh"
  [ "${status}" -eq 0 ]
  grep -q "^skopeo inspect --raw docker://quay.io/fedora/fedora-iot@${NEW_FEDORA}\$" "${MOCK_LOG}"
}

@test "a second run reports every pin as current and changes nothing" {
  "${REPO}/tools/update-pins.sh"
  cp -R "${REPO}" "${SANDBOX}/after"
  run "${REPO}/tools/update-pins.sh"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^current ' <<<"${output}")" -eq 3 ]
  diff -r "${SANDBOX}/after" "${REPO}"
}

@test "a registry that cannot be reached leaves every pin alone" {
  mock_cmd skopeo 'echo "level=fatal msg=\"connection refused\"" >&2; exit 1'
  run "${REPO}/tools/update-pins.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"connection refused"* ]]
  diff -r "${SANDBOX}/before" "${REPO}"
}

@test "a Podman tag that is listed but cannot be inspected leaves every pin alone" {
  mock_cmd skopeo "
    case \"\$*\" in
      *list-tags*) echo '{\"Tags\": [\"v5.10.1-immutable\"]}' ;;
      *inspect*--format*fedora-iot:44) echo '${NEW_FEDORA}' ;;
      *inspect*--format*bootc-image-builder:latest) echo '${NEW_BIB}' ;;
      *inspect*podman/stable:*) echo 'manifest unknown' >&2; exit 1 ;;
      *) echo \"unexpected: \$*\" >&2; exit 1 ;;
    esac"
  run "${REPO}/tools/update-pins.sh"
  [ "${status}" -eq 1 ]
  diff -r "${SANDBOX}/before" "${REPO}"
}

@test "an answer that is not a digest is refused" {
  mock_cmd skopeo 'case "$*" in *list-tags*) echo "{\"Tags\": [\"v5.8.9-immutable\"]}" ;; *) echo "<html>" ;; esac'
  run "${REPO}/tools/update-pins.sh"
  [ "${status}" -eq 1 ]
  diff -r "${SANDBOX}/before" "${REPO}"
}

@test "the justfile exposes the update" {
  run just --justfile "${REPO_ROOT}/justfile" --show update-pins
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tools/update-pins.sh"* ]]
}
