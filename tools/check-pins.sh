#!/usr/bin/env bash
# Verify that every pinned image reference still resolves in its registry.
#
# Registry pins rot silently: quay garbage-collects the manifests behind its
# daily-rebuilt tags, so a pinned digest eventually answers "manifest unknown"
# and the next build fails with an opaque registry error. This runs before a
# build (CI does) and names the file, the reference and the command that bumps
# it.
#
# Needs network. SKOPEO selects the binary, so tests can put a mock on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKOPEO="${SKOPEO:-skopeo}"

# Pinned references: "<file>|<variable>|<how to bump it>". Everything that a
# build pulls from a registry by digest or by a tag that is pushed once belongs
# here; the moving tags themselves (Fedora's `44`, bootc-image-builder's
# `latest`) are not pinned and need no check.
PINS=(
  "image/versions.env|FEDORA_IOT_IMAGE|bump it to the current digest of quay.io/fedora/fedora-iot:44: just update-pins"
  "image/versions.env|HOPRD_IMAGE|bump the tag, image digest and both binary hashes together by hand"
  "tools/build-disk.sh|BIB_IMAGE|bump it to the current digest of quay.io/centos-bootc/bootc-image-builder:latest: just update-pins"
  "tools/builder.sh|PODMAN_IMAGE|bump it to the newest vX.Y.Z-immutable tag and its digest: just update-pins"
)

# pin_value FILE VARIABLE: the reference assigned to VARIABLE, quotes removed.
pin_value() {
  grep -m1 "^$2=" "$1" | cut -d= -f2- | tr -d '"'
}

# inspect_ref REFERENCE: what to hand to skopeo. A pinned digest wins over the
# tag, and skopeo rejects "name:tag@digest" outright, so the tag is dropped
# (a registry port is not a tag and stays).
inspect_ref() {
  local ref="$1" name digest
  if [[ "${ref}" != *@* ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi
  name="${ref%@*}"
  digest="${ref#*@}"
  if [[ "${name}" =~ ^(.+/[^:/]+):[^/]+$ ]]; then
    name="${BASH_REMATCH[1]}"
  fi
  printf '%s@%s\n' "${name}" "${digest}"
}

# check_pin FILE VARIABLE HINT
# --raw only fetches the manifest: without it skopeo picks the host's
# platform out of a multi-arch index and fails on a Darwin host.
check_pin() {
  local file="$1" variable="$2" hint="$3" value error
  value="$(pin_value "${REPO_ROOT}/${file}" "${variable}")" || value=""
  if [[ -z "${value}" ]]; then
    echo "FAIL ${file}: no ${variable}= line" >&2
    return 1
  fi
  if error="$("${SKOPEO}" inspect --raw "docker://$(inspect_ref "${value}")" 2>&1 >/dev/null)"; then
    echo "ok   ${file}: ${variable} ${value}"
    return 0
  fi
  echo "FAIL ${file}: ${variable} ${value}" >&2
  # The last line of skopeo's message says whether the manifest is gone or the
  # registry could not be reached at all.
  echo "     ${error##*$'\n'}" >&2
  echo "     ${hint}" >&2
  return 1
}

main() {
  local failures=0 pin file variable hint
  if ! command -v "${SKOPEO}" >/dev/null; then
    echo "need ${SKOPEO} on PATH to check the pins" >&2
    return 1
  fi
  for pin in "${PINS[@]}"; do
    IFS='|' read -r file variable hint <<< "${pin}"
    check_pin "${file}" "${variable}" "${hint}" || failures=$((failures + 1))
  done
  if (( failures > 0 )); then
    echo "${failures} pinned image reference(s) no longer resolve" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
