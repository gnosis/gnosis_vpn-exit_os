#!/usr/bin/env bash
# Validate deployment inputs; with a root directory, configure the built image.
# No source-tree files are changed by the build.
set -euo pipefail

: "${GVPN_IMAGE_REPO:?Set GVPN_IMAGE_REPO to a registry/repository without a tag}"

repo_re='^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)+$'
if [[ ! "${GVPN_IMAGE_REPO}" =~ ${repo_re} ]]; then
  echo 'GVPN_IMAGE_REPO must be a registry/repository without a scheme, tag or digest' >&2
  exit 1
fi

[[ $# -gt 0 ]] || exit 0
root="${1%/}"
temp="$(mktemp)"
trap 'rm -f "${temp}"' EXIT

jq --arg repo "${GVPN_IMAGE_REPO}" '
  .transports.docker = {($repo): .transports.docker["registry.example.org/gvpn-exit-os"]}
' "${root}/etc/containers/policy.json" > "${temp}"
install -m 0644 "${temp}" "${root}/etc/containers/policy.json"
