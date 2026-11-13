#!/usr/bin/env bats
# tools/promote.sh promotes an existing published image version or digest to a channel
# tag (canary or stable) in the registry repository, verifying the signature against
# the image-update public key before moving the channel tag.

load helpers

PROMOTE="${REPO_ROOT}/tools/promote.sh"
REPO="registry.example.org:5443/fleet/exit-os"
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"

setup() {
  setup_sandbox
  export GVPN_IMAGE_REPO="${REPO}"
  export GVPN_COSIGN_PUB="${SANDBOX}/cosign.pub"
  write_public_key "${GVPN_COSIGN_PUB}"
  mock_cmd cosign
  write_skopeo
  export GVPN_BUILDER="${MOCK_BIN}/builder"
  mock_cmd builder
}

teardown() {
  teardown_sandbox
}

write_skopeo() {
  mock_cmd skopeo "
case \"\$*\" in
  *'inspect'*':1.2.3') echo '${DIGEST}' ;;
  *'inspect'*':canary') echo '${DIGEST}' ;;
  *'inspect'*':stable') echo '${DIGEST}' ;;
  *'inspect'*'@${DIGEST}') echo '${DIGEST}' ;;
  *'inspect'*) echo 'manifest unknown' >&2; exit 1 ;;
esac"
}

@test "promotes a version to canary after verifying signature against the update public key" {
  run "${PROMOTE}" 1.2.3 canary
  [ "${status}" -eq 0 ]
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  grep -qx "skopeo copy --insecure-policy --preserve-digests --remove-signatures docker://${REPO}@${DIGEST} docker://${REPO}:canary" "${MOCK_LOG}"
  verify_line="$(grep -n '^cosign verify' "${MOCK_LOG}" | cut -d: -f1)"
  move_line="$(grep -n ":canary$" "${MOCK_LOG}" | grep 'skopeo copy' | cut -d: -f1)"
  (( verify_line < move_line ))
  [[ "${output}" == *"promoted ${REPO}:1.2.3 (${DIGEST}) to canary"* ]]
}

@test "promotes a version to stable after verifying signature against the update public key" {
  run "${PROMOTE}" 1.2.3 stable
  [ "${status}" -eq 0 ]
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  grep -qx "skopeo copy --insecure-policy --preserve-digests --remove-signatures docker://${REPO}@${DIGEST} docker://${REPO}:stable" "${MOCK_LOG}"
  [[ "${output}" == *"promoted ${REPO}:1.2.3 (${DIGEST}) to stable"* ]]
}

@test "promotes directly by digest" {
  run "${PROMOTE}" "${DIGEST}" stable
  [ "${status}" -eq 0 ]
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  grep -qx "skopeo copy --insecure-policy --preserve-digests --remove-signatures docker://${REPO}@${DIGEST} docker://${REPO}:stable" "${MOCK_LOG}"
}

@test "fails when the version cannot be found in the registry" {
  run "${PROMOTE}" nonexistent canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cannot resolve"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "reports why the registry lookup failed, not just that it did" {
  mock_cmd skopeo 'echo "unauthorized: authentication required" >&2; exit 1'
  run "${PROMOTE}" 1.2.3 canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unauthorized: authentication required"* ]]
}

@test "never moves the channel when the signature does not verify" {
  mock_cmd cosign 'exit 1'
  run "${PROMOTE}" 1.2.3 canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "refuses invalid channel names" {
  for ch in "canary bad" "-bad" ""; do
    run "${PROMOTE}" 1.2.3 "${ch}"
    [ "${status}" -ne 0 ]
  done
}

# A version tag is published once and never overwritten (tools/publish.sh
# refuses to), so promotion may only move the two mutable channels.
@test "refuses a promotion target that is not canary or stable" {
  for ch in latest 1.2.4 canary-2; do
    run "${PROMOTE}" 1.2.3 "${ch}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"canary or stable"* ]]
  done
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "the justfile passes promote arguments as arguments, not as shell source" {
  mkdir -p "${SANDBOX}/tools"
  cat > "${SANDBOX}/tools/promote.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${SANDBOX}/argv"
EOF
  chmod +x "${SANDBOX}/tools/promote.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  run just --justfile "${SANDBOX}/justfile" promote "1.2.3; touch ${SANDBOX}/pwned" canary
  [ "${status}" -eq 0 ]
  [ ! -e "${SANDBOX}/pwned" ]
  [ "$(cat "${SANDBOX}/argv")" = "$(printf '%s\n' "1.2.3; touch ${SANDBOX}/pwned" canary)" ]
}

@test "requires arguments" {
  run "${PROMOTE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Usage"* ]]
}

@test "requires GVPN_IMAGE_REPO" {
  run env -u GVPN_IMAGE_REPO "${PROMOTE}" 1.2.3 canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_IMAGE_REPO"* ]]
}

# cosign takes any file as --key, so a private key would verify nothing and the
# channel must not move.
@test "refuses a private key as the update public key" {
  { echo '-----BEGIN PRIVATE KEY-----'; echo '-----END PRIVATE KEY-----'; } > "${GVPN_COSIGN_PUB}"
  run "${PROMOTE}" 1.2.3 canary
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PUB"* ]]
  [[ "${output}" == *"not a PEM public key"* ]]
  run grep -e '^cosign' -e '^skopeo' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

# The installer ISO of a promotion embeds the promoted image itself: it is
# pulled by the digest whose signature verified and becomes the builder's
# local image, the one the disk build reads.
@test "--pull verifies a version and makes it the builder's local image" {
  run "${PROMOTE}" --pull 1.2.3
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -qx "cosign verify --key ${GVPN_COSIGN_PUB} --insecure-ignore-tlog=true ${REPO}@${DIGEST}" "${MOCK_LOG}"
  grep -qx "builder podman pull ${REPO}@${DIGEST}" "${MOCK_LOG}"
  grep -qx "builder podman tag ${REPO}@${DIGEST} localhost/gvpn-exit-os:dev" "${MOCK_LOG}"
  verify_line="$(grep -n '^cosign verify' "${MOCK_LOG}" | cut -d: -f1)"
  pull_line="$(grep -n '^builder podman pull' "${MOCK_LOG}" | cut -d: -f1)"
  (( verify_line < pull_line ))
  # Nothing in the registry moves.
  run grep '^skopeo copy' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "--pull takes no image whose signature does not verify" {
  mock_cmd cosign 'exit 1'
  run "${PROMOTE}" --pull 1.2.3
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"does not verify"* ]]
  run grep '^builder' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "--pull needs a version" {
  run "${PROMOTE}" --pull
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Usage"* ]]
  run grep -e '^builder' -e '^cosign' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "the justfile pulls a promoted version as the image the disk build reads" {
  mkdir -p "${SANDBOX}/tools"
  cat > "${SANDBOX}/tools/promote.sh" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\${SOURCE_TAG}" "\$@" > "${SANDBOX}/argv"
SCRIPT
  chmod +x "${SANDBOX}/tools/promote.sh"
  cp "${REPO_ROOT}/justfile" "${SANDBOX}/justfile"
  run just --justfile "${SANDBOX}/justfile" pull-image 1.2.3
  [ "${status}" -eq 0 ]
  [ "$(cat "${SANDBOX}/argv")" = "$(printf '%s\n' localhost/gvpn-exit-os:dev --pull 1.2.3)" ]
}
