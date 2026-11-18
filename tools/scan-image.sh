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
# The built image is rechunked (tools/build-image.sh), so it shares no layer
# with the base image: the pinned base image (FEDORA_IOT_IMAGE) is scanned as
# well. A finding of the built image is inherited when the base image has the
# same vulnerability in the same module version, as a base package that the
# build left as it was does. A pull request cannot fix those, since the base
# moves by `just update-pins`; they are counted, not failed on. A base finding
# the built image no longer ships, in a package the build removed or upgraded,
# is not counted. Every other finding is added by this build, and a critical or
# high one fails the scan unless .trivyignore.yaml lists it with the reason it
# does not apply.
#
# Trivy names a file of a bootc image after its object in the image's ostree
# repository (sysroot/ostree/repo/objects/XX/....file). The report names it
# after the path it is installed at instead, from `ostree ls` of the image's
# commit, and .trivyignore.yaml's paths are matched against that path.
#
#   SOURCE_TAG             image to scan (default: localhost/gvpn-exit-os:dev)
#   GVPN_BUILDER           command that runs podman (default: tools/builder.sh)
#   GVPN_SCAN_DIR          where the image exports and Trivy's JSON reports go,
#                          inside the repository, the only path the builder can
#                          write (default: output/scan); the exports are removed
#   GVPN_SCAN_IGNORE_FILE  the accepted findings (default: .trivyignore.yaml)
#   GITHUB_STEP_SUMMARY    the report is appended there too (GitHub Actions)
#   TRIVY                  the binary, so tests can put a mock on PATH
#
# The base image comes from the builder's storage, where `just build` put it.
# Needs network: Trivy downloads its vulnerability database.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../image/versions.env
source "${REPO_ROOT}/image/versions.env"

TRIVY="${TRIVY:-trivy}"
SOURCE_TAG="${SOURCE_TAG:-localhost/gvpn-exit-os:dev}"
GVPN_BUILDER="${GVPN_BUILDER:-${REPO_ROOT}/tools/builder.sh}"
GVPN_SCAN_DIR="${GVPN_SCAN_DIR:-output/scan}"
IGNORE_FILE="${GVPN_SCAN_IGNORE_FILE:-${REPO_ROOT}/.trivyignore.yaml}"
ARCHIVE="${GVPN_SCAN_DIR}/image.tar"

# Trivy's JSON of the built image on stdin, $base_report that of the base image:
# {failing, report}, the number of critical and high findings the build adds and
# the Markdown report. Counts are of distinct advisories, as the registry's
# scanner counts them; the table lists every added finding.
# shellcheck disable=SC2016 # jq's variables, expanded by jq
RESULT_JQ='
def key: [.VulnerabilityID, .PkgName, .InstalledVersion];
def severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"];
def findings: [.Results[]? | .Target as $target | .Vulnerabilities[]? | . + {Target: $target}];
def counts: (map(.VulnerabilityID + " " + .Severity) | unique | map(split(" ")[1])) as $found
  | [severities[] as $severity | $found | map(select(. == $severity)) | length | tostring]
  | join(" | ");
($base_report[0] | [findings[] | key] | unique) as $base_keys
| findings as $all
| [$all[] | select(key | IN($base_keys[]))] as $inherited
| [$all[] | select(key | IN($base_keys[]) | not)] as $added
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

# installed_paths IMAGE: a JSON object from the path Trivy reports for each
# regular file of IMAGE's ostree commit to the path it is installed at. `ostree
# ls` prints a file as MODE UID GID SIZE CHECKSUM PATH, and the object of
# checksum XXYYYY... is objects/XX/YYYY....file.
installed_paths() {
  local commit
  commit="$("${GVPN_BUILDER}" podman image inspect --format '{{index .Labels "ostree.commit"}}' "$1")"
  [[ -n "${commit}" ]] || { echo "image $1 has no ostree.commit label" >&2; return 1; }
  "${GVPN_BUILDER}" podman run --rm --network=none "$1" \
    ostree --repo=/sysroot/ostree/repo ls -R -C "${commit}" \
    | sed -nE 's|^-[0-7]+ +[0-9]+ +[0-9]+ +[0-9]+ +([0-9a-f]{2})([0-9a-f]{62}) +/(.*)$|sysroot/ostree/repo/objects/\1/\2.file\t\3|p' \
    | jq -Rn 'reduce inputs as $line ({}; ($line | split("\t")) as [$object, $path] | .[$object] = $path)'
}

# scan IMAGE NAME: GVPN_SCAN_DIR/NAME.json, Trivy's report of IMAGE with its
# files named by their installed paths and the ignore file applied. Trivy reads
# `docker save` archives, not Podman's OCI archive.
scan() {
  local image="$1" raw="${GVPN_SCAN_DIR}/$2.raw.json" paths="${GVPN_SCAN_DIR}/$2.paths.json"
  local report="${GVPN_SCAN_DIR}/$2.json"
  rm -f "${ARCHIVE}" "${raw}" "${paths}" "${report}"
  "${GVPN_BUILDER}" podman save --format docker-archive -o "${ARCHIVE}" "${image}"
  "${TRIVY}" image --input "${ARCHIVE}" --scanners vuln \
    --format json --output "${raw}" --no-progress --skip-version-check
  rm -f "${ARCHIVE}"

  installed_paths "${image}" > "${paths}"
  jq --slurpfile paths "${paths}" \
    '$paths[0] as $installed | .Results |= ((. // []) | map(.Target |= ($installed[.] // .)))' \
    "${raw}" > "${report}"
  mv "${report}" "${raw}"
  "${TRIVY}" convert --format json --ignorefile "${IGNORE_FILE}" --quiet --output "${report}" "${raw}"
  rm -f "${raw}" "${paths}"
}

main() {
  local result
  cd "${REPO_ROOT}"
  mkdir -p "${GVPN_SCAN_DIR}"
  trap 'rm -f "${ARCHIVE}"' EXIT
  scan "${FEDORA_IOT_IMAGE}" trivy-base
  scan "${SOURCE_TAG}" trivy

  result="$(jq -c --slurpfile base_report "${GVPN_SCAN_DIR}/trivy-base.json" --arg tag "${SOURCE_TAG}" \
    "${RESULT_JQ}" "${GVPN_SCAN_DIR}/trivy.json")"
  jq -r '.report' <<< "${result}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    jq -r '.report' <<< "${result}" >> "${GITHUB_STEP_SUMMARY}"
  fi
  [[ "$(jq -r '.failing' <<< "${result}")" -eq 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
