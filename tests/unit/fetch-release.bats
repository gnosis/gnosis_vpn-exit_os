#!/usr/bin/env bats
# fetch-release.sh (image build): download a release asset and accept it only
# if both the pinned sha256 and the detached signature against the pinned
# release key verify.

load helpers

setup() {
  setup_sandbox
  FETCH="${REPO_ROOT}/image/build/fetch-release.sh"
  export GNUPGHOME="${SANDBOX}/gnupg"
  mkdir -m 700 "${GNUPGHOME}"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Release <release@example.org>' ed25519 sign never
  gpg --batch --quiet --armor --export release@example.org > "${SANDBOX}/release.asc"

  mkdir -p "${SANDBOX}/dl"
  echo "binary v1" > "${SANDBOX}/dl/tool-x86_64-linux"
  gpg --batch --quiet --armor --detach-sign -o "${SANDBOX}/dl/tool-x86_64-linux.asc" "${SANDBOX}/dl/tool-x86_64-linux"
  SHA="$(sha256sum "${SANDBOX}/dl/tool-x86_64-linux" | cut -d' ' -f1)"
  URL="file://${SANDBOX}/dl/tool-x86_64-linux"
  OUT="${SANDBOX}/out/tool"
  mkdir -p "${SANDBOX}/out"
}

teardown() {
  gpgconf --kill all 2>/dev/null || true
  teardown_sandbox
}

@test "accepts an asset with matching checksum and signature" {
  run "${FETCH}" "${URL}" "${SHA}" "${SANDBOX}/release.asc" "${OUT}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${OUT}")" = "binary v1" ]
  [ -x "${OUT}" ]
}

@test "rejects a checksum mismatch" {
  run "${FETCH}" "${URL}" "0000000000000000000000000000000000000000000000000000000000000000" "${SANDBOX}/release.asc" "${OUT}"
  [ "${status}" -ne 0 ]
  [ ! -e "${OUT}" ]
}

@test "rejects a signature from a different key" {
  export GNUPGHOME="${SANDBOX}/other"
  mkdir -m 700 "${GNUPGHOME}"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <other@example.org>' ed25519 sign never
  gpg --batch --quiet --armor --export other@example.org > "${SANDBOX}/other.asc"
  run "${FETCH}" "${URL}" "${SHA}" "${SANDBOX}/other.asc" "${OUT}"
  [ "${status}" -ne 0 ]
  [ ! -e "${OUT}" ]
}

@test "rejects a tampered asset even with the pinned checksum updated" {
  echo "binary v2" > "${SANDBOX}/dl/tool-x86_64-linux"
  sha="$(sha256sum "${SANDBOX}/dl/tool-x86_64-linux" | cut -d' ' -f1)"
  run "${FETCH}" "${URL}" "${sha}" "${SANDBOX}/release.asc" "${OUT}"
  [ "${status}" -ne 0 ]
  [ ! -e "${OUT}" ]
}
