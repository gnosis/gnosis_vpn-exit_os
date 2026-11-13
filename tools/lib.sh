#!/usr/bin/env bash
# Helpers shared by the host-side tools. Sourced, never executed.

# base64_one_line [FILE]
# The base64 of FILE, or of stdin without an argument, as one line without a
# trailing newline: a build arg, a TOML value and a kickstart line each have to
# be one line. BSD base64 has no `-w`, so the newlines are removed instead of
# asking base64 not to wrap.
base64_one_line() {
  local file="${1:-}"
  if [[ -n "${file}" ]]; then
    base64 < "${file}" | tr -d '\n'
  else
    base64 | tr -d '\n'
  fi
}

# The channel tags a device can track. A version tag is published once and
# never overwritten, so an image, an installer, an update and a promotion
# follow one of these or nothing.
# shellcheck disable=SC2034 # read by the scripts that source this file
GVPN_CHANNEL_RE='^(canary|stable)$'

# iso_repo
# Print the repository the installer ISO is published to and pulled from,
# GVPN_ISO_REPO. It is a repository of its own: the ISO is tagged with the
# plain version and channel, which in the image repository would replace the
# image's own tags, and devices pull the image's channel.
iso_repo() {
  local repo="${GVPN_ISO_REPO:-}"
  if [[ -z "${repo}" ]]; then
    echo "Set GVPN_ISO_REPO to the installer ISO repository, a repository apart from the image's" >&2
    return 1
  fi
  if [[ ! "${repo}" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-]+[a-z0-9]+)*)+$ ]]; then
    echo "GVPN_ISO_REPO must be a registry/repository without a scheme, tag or digest" >&2
    return 1
  fi
  if [[ "${repo}" == "${GVPN_IMAGE_REPO:-}" ]]; then
    echo "GVPN_ISO_REPO is the image repository ${repo}; the ISO's version and channel tags would replace the image's, so give the ISO a repository of its own" >&2
    return 1
  fi
  printf '%s\n' "${repo}"
}

# require_public_key FILE [VARIABLE]
# Accept FILE only as a PEM public key. cosign takes any file as --key, so a
# private key or an SSH key given as the update public key builds an image
# whose devices verify nothing and publishes a version tag that cannot verify:
# refuse it before anything is built or pushed.
require_public_key() {
  local file="$1" variable="${2:-GVPN_COSIGN_PUB}" first last
  if [[ ! -s "${file}" ]]; then
    echo "${variable}: no update public key at ${file}" >&2
    echo "Create a pair with 'cosign generate-key-pair', then point ${variable} at the .pub" >&2
    return 1
  fi
  # A key pasted into a CI variable arrives with CRLF line endings or trailing
  # blanks as often as without, so the marker lines are compared without either.
  first="$(grep -m1 -v '^[[:space:]]*$' "${file}" | sed 's/[[:space:]]*$//' || true)"
  last="$(grep -v '^[[:space:]]*$' "${file}" | tail -n1 | sed 's/[[:space:]]*$//' || true)"
  if [[ "${first}" != '-----BEGIN PUBLIC KEY-----' ]] \
    || [[ "${last}" != '-----END PUBLIC KEY-----' ]] \
    || grep -q 'PRIVATE KEY' "${file}"; then
    echo "${variable}: ${file} is not a PEM public key (first line: '${first}')" >&2
    echo "Point ${variable} at the .pub file of 'cosign generate-key-pair'" >&2
    return 1
  fi
}
