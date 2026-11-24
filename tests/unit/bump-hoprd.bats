#!/usr/bin/env bats
# tools/bump-hoprd.sh moves the hoprd pin of image/versions.env to a release:
# version, image tag and digest, and the hashes of both binaries together.
# It runs against a copy of the versions file, with skopeo and the container
# engine mocked, so the real pin never moves.

load helpers

NEW_DIGEST="sha256:$(printf 'a%.0s' {1..64})"

setup() {
  setup_sandbox
  REPO="${SANDBOX}/repo"
  mkdir -p "${REPO}/tools" "${REPO}/image"
  cp "${REPO_ROOT}/tools/bump-hoprd.sh" "${REPO_ROOT}/tools/check-pins.sh" "${REPO}/tools/"
  cp "${REPO_ROOT}/image/versions.env" "${REPO}/image/"
  cp -R "${REPO}" "${SANDBOX}/before"
  mock_cmd skopeo "
    case \"\$*\" in
      *inspect*--format*/hoprd:5.9.9) echo '${NEW_DIGEST}' ;;
      *inspect*--raw*) exit 0 ;;
      *) echo \"unexpected: \$*\" >&2; exit 1 ;;
    esac"
  # A container whose binaries are told apart by their content.
  mock_cmd docker '
    case "$1" in
      create) echo cid ;;
      cp) shift; [[ "$1" == "-L" ]] && shift; printf "%s" "${1#cid:/bin/}" > "$2" ;;
      rm) ;;
    esac'
  HOPRD_SHA="$(printf hoprd | sha256sum | cut -d' ' -f1)"
  CFG_SHA="$(printf hoprd-cfg | sha256sum | cut -d' ' -f1)"
}

teardown() {
  teardown_sandbox
}

pin() {
  grep "^$1=" "${REPO}/image/versions.env"
}

@test "version, image, and both hashes move together" {
  run "${REPO}/tools/bump-hoprd.sh" 5.9.9
  [ "${status}" -eq 0 ]
  [ "$(pin HOPRD_VERSION)" = "HOPRD_VERSION=5.9.9" ]
  [ "$(pin HOPRD_IMAGE)" = "HOPRD_IMAGE=europe-west3-docker.pkg.dev/hoprassociation/docker-images/hoprd:5.9.9@${NEW_DIGEST}" ]
  [ "$(pin HOPRD_SHA256)" = "HOPRD_SHA256=${HOPRD_SHA}" ]
  [ "$(pin HOPRD_CFG_SHA256)" = "HOPRD_CFG_SHA256=${CFG_SHA}" ]
}

@test "nothing but the four pinned lines changes" {
  "${REPO}/tools/bump-hoprd.sh" 5.9.9
  [ "$(diff -r "${SANDBOX}/before" "${REPO}" | grep -c '^>')" -eq 4 ]
}

@test "the digest is resolved for the platform the appliances run" {
  "${REPO}/tools/bump-hoprd.sh" 5.9.9
  grep -q -- '--override-os linux --override-arch amd64 .*docker://.*/hoprd:5.9.9$' "${MOCK_LOG}"
}

@test "the binaries are taken from the image at the resolved digest" {
  "${REPO}/tools/bump-hoprd.sh" 5.9.9
  grep -q "^docker create --platform linux/amd64 .*/hoprd@${NEW_DIGEST}\$" "${MOCK_LOG}"
  grep -q '^docker cp -L cid:/bin/hoprd ' "${MOCK_LOG}"
  grep -q '^docker cp -L cid:/bin/hoprd-cfg ' "${MOCK_LOG}"
}

@test "the new image is checked against the registry" {
  "${REPO}/tools/bump-hoprd.sh" 5.9.9
  grep -q "^skopeo inspect --raw docker://.*/hoprd@${NEW_DIGEST}\$" "${MOCK_LOG}"
}

@test "the version already pinned changes nothing" {
  current="$(pin HOPRD_VERSION)"
  run "${REPO}/tools/bump-hoprd.sh" "${current#HOPRD_VERSION=}"
  [ "${status}" -eq 0 ]
  diff -r "${SANDBOX}/before" "${REPO}"
}

@test "a version that is not one is refused" {
  run "${REPO}/tools/bump-hoprd.sh" 'v5.9.9; rm -rf /'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a hoprd version"* ]]
  diff -r "${SANDBOX}/before" "${REPO}"
}

@test "a tag the registry does not have leaves the pin alone" {
  mock_cmd skopeo 'echo "manifest unknown" >&2; exit 1'
  run "${REPO}/tools/bump-hoprd.sh" 5.9.9
  [ "${status}" -eq 1 ]
  diff -r "${SANDBOX}/before" "${REPO}"
}

@test "a binary that does not come out leaves the pin alone" {
  mock_cmd docker 'case "$1" in create) echo cid ;; cp) exit 1 ;; esac'
  run "${REPO}/tools/bump-hoprd.sh" 5.9.9
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot copy"* ]]
  diff -r "${SANDBOX}/before" "${REPO}"
}
