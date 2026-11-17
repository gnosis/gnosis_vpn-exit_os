#!/usr/bin/env bats
# tools/scan-image.sh scans the built image with Trivy and fails only on the
# critical and high vulnerabilities that the build adds to the pinned base
# image: the base moves by `just update-pins`, so a pull request cannot fix
# what the base ships.

load helpers

SCRIPT="${REPO_ROOT}/tools/scan-image.sh"
BASE_LAYER="sha256:1111111111111111111111111111111111111111111111111111111111111111"
BUILD_LAYER="sha256:2222222222222222222222222222222222222222222222222222222222222222"

setup() {
  setup_sandbox
  export GVPN_SCAN_DIR="${SANDBOX}/scan"
  export GITHUB_STEP_SUMMARY="${SANDBOX}/summary.md"
  export GVPN_BUILDER="${MOCK_BIN}/builder"
  # podman save: leaves the archive where -o says.
  mock_cmd builder 'while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && : > "$2"; shift; done'
  # The pinned base image's config: its layers.
  mock_cmd skopeo "echo '{\"rootfs\":{\"diff_ids\":[\"${BASE_LAYER}\"]}}'"
  # Trivy: writes the prepared report where --output says.
  mock_cmd trivy 'while [[ $# -gt 0 ]]; do [[ "$1" == --output ]] && cp "${SANDBOX}/trivy.json" "$2"; shift; done'
}

teardown() {
  teardown_sandbox
}

# finding LAYER FILE ID MODULE VERSION SEVERITY: one Trivy result.
finding() {
  jq -n --arg layer "$1" --arg target "$2" --arg id "$3" --arg pkg "$4" --arg version "$5" --arg severity "$6" '{
    Target: $target, Class: "lang-pkgs", Type: "gobinary",
    Vulnerabilities: [{VulnerabilityID: $id, PkgName: $pkg, InstalledVersion: $version,
      FixedVersion: "9.9.9", Severity: $severity, Layer: {DiffID: $layer}}]
  }'
}

# Collects the findings on stdin into the report the Trivy mock writes.
write_report() {
  jq -s '{SchemaVersion: 2, Results: .}' > "${SANDBOX}/trivy.json"
}

@test "fails on a high vulnerability in a module version the base image does not ship" {
  # The same advisory in the same module, but the base ships another version:
  # updating netdata fixes the build's copy, and only a base bump fixes the other.
  {
    finding "${BASE_LAYER}" sysroot/ostree/repo/objects/8f/7f.file CVE-2026-84304 google.golang.org/grpc v1.72.2 HIGH
    finding "${BUILD_LAYER}" usr/libexec/netdata/plugins.d/go.d.plugin CVE-2026-84304 google.golang.org/grpc v1.83.0 HIGH
  } | write_report
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"| HIGH | CVE-2026-84304 | google.golang.org/grpc | v1.83.0 | 9.9.9 | usr/libexec/netdata/plugins.d/go.d.plugin |"* ]]
  [[ "${output}" != *"v1.72.2"* ]]
  [[ "${output}" == *"1 critical or high vulnerabilities added by this build"* ]]
  [[ "${output}" == *".trivyignore.yaml"* ]]
  grep -qF '| HIGH | CVE-2026-84304 | google.golang.org/grpc | v1.83.0 |' "${GITHUB_STEP_SUMMARY}"
}

@test "passes when every critical or high finding comes with the base image" {
  {
    finding "${BASE_LAYER}" sysroot/ostree/repo/objects/8f/7f.file CVE-2026-33186 google.golang.org/grpc v1.72.2 CRITICAL
    finding "${BASE_LAYER}" sysroot/ostree/repo/objects/5a/23.file CVE-2026-56853 stdlib v1.26.5 HIGH
    # A base package that dnf upgraded and that still links the same version.
    finding "${BUILD_LAYER}" usr/bin/podman CVE-2026-33186 google.golang.org/grpc v1.72.2 CRITICAL
    finding "${BUILD_LAYER}" usr/bin/node_exporter CVE-2026-78659 golang.org/x/net v0.57.0 MEDIUM
  } | write_report
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"| Added by this build | 0 | 0 | 1 | 0 | 0 |"* ]]
  [[ "${output}" == *"| Inherited from the base image | 1 | 1 | 0 | 0 | 0 |"* ]]
  [[ "${output}" == *"| MEDIUM | CVE-2026-78659 | golang.org/x/net | v0.57.0 | 9.9.9 | usr/bin/node_exporter |"* ]]
  [[ "${output}" != *"| CRITICAL | CVE-2026-33186 |"* ]]
  grep -qF '| Inherited from the base image | 1 | 1 | 0 | 0 | 0 |' "${GITHUB_STEP_SUMMARY}"
}

@test "scans the exported build against the pinned base image's layers, then removes the export" {
  finding "${BASE_LAYER}" sysroot/ostree/repo/objects/5a/23.file CVE-2026-56853 stdlib v1.26.5 HIGH | write_report
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local archive="${GVPN_SCAN_DIR}/image.tar" base
  base="$(sed -n 's/^FEDORA_IOT_IMAGE=quay.io\/fedora\/fedora-iot:44@//p' "${REPO_ROOT}/image/versions.env")"
  # Trivy reads `docker save` archives, not Podman's OCI archive.
  grep -qx "builder podman save --format docker-archive -o ${archive} localhost/gvpn-exit-os:dev" "${MOCK_LOG}"
  grep -qx "skopeo inspect --config --override-os linux --override-arch amd64 docker://quay.io/fedora/fedora-iot@${base}" "${MOCK_LOG}"
  grep -q "^trivy image --input ${archive} .*--ignorefile ${REPO_ROOT}/.trivyignore.yaml" "${MOCK_LOG}"
  [ ! -e "${archive}" ]
  [ -s "${GVPN_SCAN_DIR}/trivy.json" ]
}
