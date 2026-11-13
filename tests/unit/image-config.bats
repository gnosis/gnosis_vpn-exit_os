#!/usr/bin/env bats
# Deployment inputs are rendered into the image, never into the source tree.

load helpers

CONFIGURE="${REPO_ROOT}/image/build/configure-image.sh"

setup() {
  setup_sandbox
  export GVPN_IMAGE_REPO="registry.example.org:5443/fleet/exit-os"
  IMAGE_ROOT="${SANDBOX}/image"
  mkdir -p "${IMAGE_ROOT}/etc/containers" "${IMAGE_ROOT}/usr/share/gvpn-exit"
  cp "${ROOTFS}/etc/containers/policy.json" "${IMAGE_ROOT}/etc/containers/"
  cp "${SHARE}/hoprd.cfg.yaml" "${IMAGE_ROOT}/usr/share/gvpn-exit/"
}

teardown() {
  teardown_sandbox
}

@test "renders a repository-scoped signed update policy and preserves placeholder config" {
  run bash "${CONFIGURE}" "${IMAGE_ROOT}"
  [ "${status}" -eq 0 ]
  policy="${IMAGE_ROOT}/etc/containers/policy.json"
  jq -e --arg repo "${GVPN_IMAGE_REPO}" '
    (.transports.docker | keys) == [$repo] and
    .transports.docker[$repo] == [{
      type: "sigstoreSigned", keyPath: "/etc/pki/containers/gvpn-exit-os.pub",
      signedIdentity: {type: "matchRepository"}
    }] and .default == [{type: "reject"}] and
    .transports["containers-storage"][""] == [{type: "insecureAcceptAnything"}]
  ' "${policy}"
  [ "$(awk '/^blokli_url:/ {print $2}' "${IMAGE_ROOT}/usr/share/gvpn-exit/hoprd.cfg.yaml")" = "https://blokli.example.org" ]
  [[ "$(cat "${IMAGE_ROOT}/usr/share/gvpn-exit/hoprd.cfg.yaml")" == *'"172.30.0.1:51820"'* ]]
  jq -e '.transports.docker | has("registry.example.org/gvpn-exit-os")' "${ROOTFS}/etc/containers/policy.json"
  [[ "$(cat "${SHARE}/hoprd.cfg.yaml")" == *'blokli_url: https://blokli.example.org'* ]]
}

@test "the netdata repository never lands in an image layer" {
  # bootc-image-builder depsolves the installer ISO from the image's layers,
  # where a file that a later layer deleted is still visible. A repo file that
  # a COPY puts in a layer therefore comes back at ISO build time, and its
  # file:// gpgkey does not resolve outside the image, so the build stops at
  # "cannot depsolve". The file is written from image/build inside the install
  # RUN and removed in the same RUN, which leaves it in no layer.
  local containerfile="${REPO_ROOT}/image/Containerfile"
  ! grep -Eq '^COPY[[:space:]].*\.repo([[:space:]]|$)' "${containerfile}"
  grep -q '> /etc/yum.repos.d/netdata.repo' "${containerfile}"
  grep -q 'rm -f /etc/yum.repos.d/netdata.repo' "${containerfile}"
}

@test "validates deployment inputs without requiring an image filesystem" {
  run bash "${CONFIGURE}"
  [ "${status}" -eq 0 ]
}

@test "rejects missing registry input before rendering" {
  run env -u GVPN_IMAGE_REPO bash "${CONFIGURE}" "${IMAGE_ROOT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_IMAGE_REPO"* ]]
  [[ "$(cat "${IMAGE_ROOT}/usr/share/gvpn-exit/hoprd.cfg.yaml")" == *'blokli_url: https://blokli.example.org'* ]]
}

@test "rejects registry schemes, tags, digests and configuration injection" {
  for repo in 'https://registry.example.org/fleet/exit' 'registry.example.org/exit:canary' \
    'registry.example.org/exit@sha256:1234' $'registry.example.org/exit\nother: true' \
    'registry.example.org/../exit'; do
    GVPN_IMAGE_REPO="${repo}" run bash "${CONFIGURE}" "${IMAGE_ROOT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GVPN_IMAGE_REPO"* ]]
  done
}
