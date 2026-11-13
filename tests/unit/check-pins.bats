#!/usr/bin/env bats
# tools/check-pins.sh turns a dead registry pin into a message that names the
# reference and the command that bumps it, instead of a raw registry error
# halfway through a build.

load helpers

setup() {
  setup_sandbox
  SCRIPT="${REPO_ROOT}/tools/check-pins.sh"
  FEDORA_DIGEST="$(sed -n 's/^FEDORA_IOT_IMAGE=.*@//p' "${REPO_ROOT}/image/versions.env")"
  # A registry where every pinned reference resolves.
  mock_cmd skopeo 'exit 0'
}

teardown() {
  teardown_sandbox
}

@test "resolves every pinned reference through skopeo" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^ok ' <<< "${output}")" -eq 4 ]
  # --raw checks the manifest without picking the host platform's image, which
  # a Darwin host would not find. The digest wins over the tag: skopeo
  # rejects "name:tag@digest".
  grep -q "^skopeo inspect --raw docker://quay.io/fedora/fedora-iot@${FEDORA_DIGEST}\$" "${MOCK_LOG}"
  grep -q "^skopeo inspect --raw docker://europe-west3-docker.pkg.dev/hoprassociation/docker-images/hoprd@sha256:[0-9a-f]*\$" "${MOCK_LOG}"
  grep -q '^skopeo inspect --raw docker://quay.io/podman/stable@sha256:[0-9a-f]*$' "${MOCK_LOG}"
  grep -q '^skopeo inspect --raw docker://quay.io/centos-bootc/bootc-image-builder@sha256:[0-9a-f]*$' "${MOCK_LOG}"
}

@test "fails with the file, the reference and the bump command for a dead pin" {
  mock_cmd skopeo "
    case \"\$*\" in
      *${FEDORA_DIGEST}) echo 'time=\"2026-10-19T20:00:00Z\" level=fatal msg=\"reading manifest: manifest unknown\"' >&2; exit 1 ;;
      *) exit 0 ;;
    esac"
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL image/versions.env: FEDORA_IOT_IMAGE quay.io/fedora/fedora-iot:44@${FEDORA_DIGEST}"* ]]
  [[ "${output}" == *"manifest unknown"* ]]
  [[ "${output}" == *"bump it to the current digest of quay.io/fedora/fedora-iot:44: just update-pins"* ]]
  [[ "${output}" == *"1 pinned image reference(s) no longer resolve"* ]]
}

@test "reports a registry that cannot be reached as a failure, not a silent pass" {
  mock_cmd skopeo 'echo "level=fatal msg=\"connection refused\"" >&2; exit 1'
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"4 pinned image reference(s) no longer resolve"* ]]
}

@test "inspects a pinned digest without its tag, keeping a registry port" {
  in_script() { bash -c 'source "$1"; shift; "$@"' _ "${SCRIPT}" "$@"; }
  [ "$(in_script inspect_ref 'quay.io/fedora/fedora-iot:44@sha256:abc')" = "quay.io/fedora/fedora-iot@sha256:abc" ]
  [ "$(in_script inspect_ref 'quay.io/podman/stable:v5.8.9-immutable')" = "quay.io/podman/stable:v5.8.9-immutable" ]
  [ "$(in_script inspect_ref 'registry.example.org:5000/fleet/exit-os@sha256:abc')" = "registry.example.org:5000/fleet/exit-os@sha256:abc" ]
  [ "$(in_script inspect_ref 'registry.example.org:5000/fleet/exit-os:canary@sha256:abc')" = "registry.example.org:5000/fleet/exit-os@sha256:abc" ]
}

@test "fails when the pinned variable disappeared from its file" {
  # The check is only as good as the files it reads: a renamed variable must not
  # pass as "nothing to check".
  mkdir -p "${SANDBOX}/repo/tools" "${SANDBOX}/repo/image"
  cp "${SCRIPT}" "${SANDBOX}/repo/tools/"
  cp "${REPO_ROOT}/tools/build-disk.sh" "${REPO_ROOT}/tools/builder.sh" "${SANDBOX}/repo/tools/"
  cp "${REPO_ROOT}/image/versions.env" "${SANDBOX}/repo/image/"
  sed -i 's/^FEDORA_IOT_IMAGE=/FEDORA_IOT_BASE_IMAGE=/' "${SANDBOX}/repo/image/versions.env"
  run "${SANDBOX}/repo/tools/check-pins.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL image/versions.env: no FEDORA_IOT_IMAGE= line"* ]]
}

@test "fails with a usable message without skopeo" {
  run env SKOPEO="${SANDBOX}/missing-skopeo" "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"need ${SANDBOX}/missing-skopeo on PATH"* ]]
}

@test "the justfile exposes the check" {
  run just --justfile "${REPO_ROOT}/justfile" --show check-pins
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"tools/check-pins.sh"* ]]
}
