#!/usr/bin/env bash
# Scan the built OS image for known vulnerabilities, and fail on the critical
# and high ones that the build adds to the pinned base image.
#
#   tools/scan-image.sh
#
# Trivy finds the Go modules and Go toolchains linked into the image's binaries.
# Like Artifact Analysis, which scans the published image, it does not recognise
# Fedora and so does not check the RPMs; the build applies Fedora's updates
# instead (image/Containerfile).
#
# A finding is inherited when it sits in a layer of the pinned base image
# (FEDORA_IOT_IMAGE), or when a base layer has the same vulnerability in the
# same module version, as a base package that dnf upgraded still does. A pull
# request cannot fix those, since the base moves by `just update-pins`; they
# are counted, not failed on. Every other finding is added by this build, and a
# critical or high one fails the scan unless .trivyignore.yaml lists it with the
# reason it does not apply.
#
#   SOURCE_TAG           image to scan (default: localhost/gvpn-exit-os:dev)
#   GVPN_BUILDER         command that runs podman (default: tools/builder.sh)
#   GVPN_SCAN_DIR        where the image export and Trivy's JSON report go,
#                        inside the repository, the only path the builder can
#                        write (default: output/scan); the export is removed
#   GITHUB_STEP_SUMMARY  the report is appended there too (GitHub Actions)
#   TRIVY, SKOPEO        the binaries, so tests can put mocks on PATH
#
# Needs network: Trivy downloads its vulnerability database.
set -euo pipefail

# shellcheck source=SCRIPTDIR/check-pins.sh
source "$(dirname "${BASH_SOURCE[0]}")/check-pins.sh"

TRIVY="${TRIVY:-trivy}"
SOURCE_TAG="${SOURCE_TAG:-localhost/gvpn-exit-os:dev}"
GVPN_BUILDER="${GVPN_BUILDER:-${REPO_ROOT}/tools/builder.sh}"
GVPN_SCAN_DIR="${GVPN_SCAN_DIR:-output/scan}"
ARCHIVE="${GVPN_SCAN_DIR}/image.tar"
REPORT="${GVPN_SCAN_DIR}/trivy.json"
IGNORE_FILE="${REPO_ROOT}/.trivyignore.yaml"

# Trivy's JSON on stdin, $base the JSON array of the base image's layer
# digests: {failing, report}, the number of critical and high findings the
# build adds and the Markdown report. Counts are of distinct advisories, as the
# registry's scanner counts them; the table lists every added finding.
# shellcheck disable=SC2016 # jq's variables, expanded by jq
RESULT_JQ='
def key: [.VulnerabilityID, .PkgName, .InstalledVersion];
def severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"];
def counts: (map(.VulnerabilityID + " " + .Severity) | unique | map(split(" ")[1])) as $found
  | [severities[] as $severity | $found | map(select(. == $severity)) | length | tostring]
  | join(" | ");
[.Results[]? | .Target as $target | .Vulnerabilities[]? | . + {Target: $target}] as $all
| ([$all[] | select(.Layer.DiffID | IN($base[])) | key] | unique) as $base_keys
| [$all[] | select(key | IN($base_keys[]))] as $inherited
| [$all[] | select((.Layer.DiffID | IN($base[]) | not) and (key | IN($base_keys[]) | not))] as $added
| ([$added[] | select(.Severity == "CRITICAL" or .Severity == "HIGH")] | length) as $failing
| {failing: $failing, report: ([
    "## Vulnerability scan of `\($tag)`",
    "",
    "| | Critical | High | Medium | Low | Unknown |",
    "| --- | --- | --- | --- | --- | --- |",
    "| Added by this build | \($added | counts) |",
    "| Inherited from the base image | \($inherited | counts) |",
    "",
    if ($added | length) == 0 then "Nothing added by this build." else
      "Added by this build:",
      "",
      "| Severity | ID | Module | Version | Fixed in | File |",
      "| --- | --- | --- | --- | --- | --- |",
      ($added | sort_by((.Severity as $s | severities | index($s)), .VulnerabilityID, .Target)[]
        | "| \(.Severity) | \(.VulnerabilityID) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion // "") | \(.Target) |")
    end,
    "",
    if $failing == 0 then "No critical or high vulnerability added by this build."
    else "\($failing) critical or high vulnerabilities added by this build: update the component, or list the finding with the reason it does not apply in .trivyignore.yaml."
    end
  ] | join("\n"))}
'

main() {
  local base base_layers result
  cd "${REPO_ROOT}"
  mkdir -p "${GVPN_SCAN_DIR}"
  trap 'rm -f "${ARCHIVE}"' EXIT
  rm -f "${ARCHIVE}" "${REPORT}"
  # Trivy reads `docker save` archives, not Podman's OCI archive.
  "${GVPN_BUILDER}" podman save --format docker-archive -o "${ARCHIVE}" "${SOURCE_TAG}"

  # Resolved for linux/amd64, the appliances' platform, like update-pins.sh.
  base="$(pin_value "${REPO_ROOT}/image/versions.env" FEDORA_IOT_IMAGE)"
  base_layers="$("${SKOPEO}" inspect --config --override-os linux --override-arch amd64 \
    "docker://$(inspect_ref "${base}")" | jq -ce '.rootfs.diff_ids')"

  "${TRIVY}" image --input "${ARCHIVE}" --scanners vuln --ignorefile "${IGNORE_FILE}" \
    --format json --output "${REPORT}" --no-progress --skip-version-check

  result="$(jq -c --argjson base "${base_layers}" --arg tag "${SOURCE_TAG}" "${RESULT_JQ}" "${REPORT}")"
  jq -r '.report' <<< "${result}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    jq -r '.report' <<< "${result}" >> "${GITHUB_STEP_SUMMARY}"
  fi
  [[ "$(jq -r '.failing' <<< "${result}")" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
