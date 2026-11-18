#!/usr/bin/env bats
# tools/scan-image.sh scans the built image with Trivy and fails only on the
# critical and high vulnerabilities that the build adds to the pinned base
# image: the base moves by `just update-pins`, so a pull request cannot fix
# what the base ships.

load helpers

SCRIPT="${REPO_ROOT}/tools/scan-image.sh"
COMMIT="0c0ffee0000000000000000000000000000000000000000000000000000000c0"
GO_D_SUM="4766dfc172de0ebf28dfcf01ccd75245e2c3af06c7373528958991275166d704"
EXPORTER_SUM="853c209bafb42004ffb402fa31e2e06cf8ff3bd9560ec8cf59871ecca994a35c"

setup() {
  # The ignore file is applied by Trivy itself, offline: the mock hands
  # `trivy convert` to the real one.
  local real_trivy
  real_trivy="$(command -v trivy)"
  setup_sandbox
  export GVPN_SCAN_DIR="${SANDBOX}/scan"
  export GITHUB_STEP_SUMMARY="${SANDBOX}/summary.md"
  export GVPN_BUILDER="${MOCK_BIN}/builder"
  mkdir -p "${SANDBOX}/reports"
  : > "${SANDBOX}/ostree-ls.txt"
  # podman save leaves the archive where -o says; the image's ostree commit
  # label; `ostree ls` in the image prints the prepared listing.
  mock_cmd builder "case \"\$2\" in
  save) while [[ \$# -gt 0 ]]; do [[ \"\$1\" == -o ]] && : > \"\$2\"; shift; done ;;
  image) echo ${COMMIT} ;;
  run) cat \"\${SANDBOX}/ostree-ls.txt\" ;;
esac"
  # trivy image writes the prepared report of the same name where --output says.
  mock_cmd trivy "if [[ \"\$1\" == convert ]]; then exec ${real_trivy} \"\$@\"; fi
while [[ \$# -gt 0 ]]; do [[ \"\$1\" == --output ]] && cp \"\${SANDBOX}/reports/\$(basename \"\$2\")\" \"\$2\"; shift; done"
}

teardown() {
  teardown_sandbox
}

# finding FILE ID MODULE VERSION SEVERITY: one Trivy result.
finding() {
  jq -n --arg target "$1" --arg id "$2" --arg pkg "$3" --arg version "$4" --arg severity "$5" '{
    Target: $target, Class: "lang-pkgs", Type: "gobinary",
    Vulnerabilities: [{VulnerabilityID: $id, PkgName: $pkg, InstalledVersion: $version,
      FixedVersion: "9.9.9", Severity: $severity}]
  }'
}

# write_report base|build: the findings on stdin as the report `trivy image`
# writes for the pinned base image or for the build.
write_report() {
  local name=trivy
  [[ "$1" == base ]] && name=trivy-base
  jq -s '{SchemaVersion: 2, ArtifactName: "image.tar", ArtifactType: "container_image", Results: .}' \
    > "${SANDBOX}/reports/${name}.raw.json"
}

# object SUM: the path Trivy reports for a file of the image's ostree repository.
object() {
  echo "sysroot/ostree/repo/objects/${1:0:2}/${1:2}.file"
}

@test "fails on a high vulnerability in a module version the base image does not ship" {
  # The same advisory in the same module, but the base ships another version:
  # updating netdata fixes the build's copy, and only a base bump fixes the other.
  finding usr/bin/podman CVE-2026-84304 google.golang.org/grpc v1.72.2 HIGH | write_report base
  {
    finding usr/bin/podman CVE-2026-84304 google.golang.org/grpc v1.72.2 HIGH
    finding usr/libexec/netdata/plugins.d/go.d.plugin CVE-2026-84304 google.golang.org/grpc v1.83.0 HIGH
  } | write_report build
  run "${SCRIPT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"| HIGH | CVE-2026-84304 | google.golang.org/grpc | v1.83.0 | 9.9.9 | usr/libexec/netdata/plugins.d/go.d.plugin |"* ]]
  [[ "${output}" != *"| HIGH | CVE-2026-84304 | google.golang.org/grpc | v1.72.2 |"* ]]
  [[ "${output}" == *"| Inherited from the base image | 0 | 1 | 0 | 0 | 0 |"* ]]
  [[ "${output}" == *"1 critical or high vulnerabilities added by this build"* ]]
  [[ "${output}" == *".trivyignore.yaml"* ]]
  grep -qF '| HIGH | CVE-2026-84304 | google.golang.org/grpc | v1.83.0 |' "${GITHUB_STEP_SUMMARY}"
}

@test "passes when every critical or high finding comes with the base image, and counts only what the image still ships" {
  {
    finding "$(object "${GO_D_SUM}")" CVE-2026-33186 google.golang.org/grpc v1.72.2 CRITICAL
    # A base package the build removes or upgrades: gone from the built image.
    finding usr/libexec/cni/bridge CVE-2026-56853 stdlib v1.26.5 HIGH
  } | write_report base
  {
    # A base package that the upgrade left at the same module version.
    finding usr/bin/podman CVE-2026-33186 google.golang.org/grpc v1.72.2 CRITICAL
    finding usr/bin/node_exporter CVE-2026-78659 golang.org/x/net v0.57.0 MEDIUM
  } | write_report build
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"| Added by this build | 0 | 0 | 1 | 0 | 0 |"* ]]
  [[ "${output}" == *"| Inherited from the base image | 1 | 0 | 0 | 0 | 0 |"* ]]
  [[ "${output}" == *"| MEDIUM | CVE-2026-78659 | golang.org/x/net | v0.57.0 | 9.9.9 | usr/bin/node_exporter |"* ]]
  [[ "${output}" != *"| CRITICAL | CVE-2026-33186 |"* ]]
  [[ "${output}" != *"CVE-2026-56853"* ]]
  grep -qF '| Inherited from the base image | 1 | 0 | 0 | 0 | 0 |' "${GITHUB_STEP_SUMMARY}"
}

@test "names the installed file of an ostree object, and matches the ignore file's paths against it" {
  # Trivy names a file of a bootc image after its object in the ostree
  # repository; `ostree ls` of the image's commit says where it is installed.
  cat > "${SANDBOX}/ostree-ls.txt" <<EOF
d00755 0 0      0 1111111111111111111111111111111111111111111111111111111111111111 2222222222222222222222222222222222222222222222222222222222222222 /usr/bin
-00755 0 0 16906136 ${EXPORTER_SUM} /usr/bin/prometheus-node-exporter
l00777 0 0      0 9164ab07e895b22d5e1247965f1c14b4e3ac9298209c66d8ebb9698ae735a4cd /usr/bin/node_exporter -> prometheus-node-exporter
-00750 0 979 200249504 ${GO_D_SUM} /usr/libexec/netdata/plugins.d/go.d.plugin
EOF
  cat > "${SANDBOX}/ignore.yaml" <<'EOF'
vulnerabilities:
  - id: CVE-2026-42151
    paths:
      - usr/libexec/netdata/plugins.d/go.d.plugin
EOF
  export GVPN_SCAN_IGNORE_FILE="${SANDBOX}/ignore.yaml"
  : | write_report base
  {
    finding "$(object "${GO_D_SUM}")" CVE-2026-42151 github.com/prometheus/prometheus v0.302.0 HIGH
    finding "$(object "${EXPORTER_SUM}")" CVE-2026-97054 stdlib v1.26.10 MEDIUM
  } | write_report build
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"| MEDIUM | CVE-2026-97054 | stdlib | v1.26.10 | 9.9.9 | usr/bin/prometheus-node-exporter |"* ]]
  [[ "${output}" != *"CVE-2026-42151"* ]]
  [[ "${output}" != *"sysroot/ostree"* ]]
}

@test "scans the exported build and the pinned base image, then removes the exports" {
  finding usr/bin/podman CVE-2026-56853 stdlib v1.26.5 HIGH | write_report base
  finding usr/bin/podman CVE-2026-56853 stdlib v1.26.5 HIGH | write_report build
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  local archive="${GVPN_SCAN_DIR}/image.tar" base image
  base="$(sed -n 's/^FEDORA_IOT_IMAGE=//p' "${REPO_ROOT}/image/versions.env")"
  for image in "${base}" localhost/gvpn-exit-os:dev; do
    # Trivy reads `docker save` archives, not Podman's OCI archive.
    grep -qx "builder podman save --format docker-archive -o ${archive} ${image}" "${MOCK_LOG}"
    grep -q "^builder podman run .* ${image} ostree --repo=/sysroot/ostree/repo ls -R -C ${COMMIT}$" "${MOCK_LOG}"
  done
  grep -q "^trivy image --input ${archive} .*--output ${GVPN_SCAN_DIR}/trivy-base.raw.json" "${MOCK_LOG}"
  grep -q "^trivy image --input ${archive} .*--output ${GVPN_SCAN_DIR}/trivy.raw.json" "${MOCK_LOG}"
  grep -q "^trivy convert .*--ignorefile ${REPO_ROOT}/.trivyignore.yaml .*--output ${GVPN_SCAN_DIR}/trivy.json" "${MOCK_LOG}"
  [ ! -e "${archive}" ]
  [ -s "${GVPN_SCAN_DIR}/trivy.json" ]
  [ -s "${GVPN_SCAN_DIR}/trivy-base.json" ]
}
