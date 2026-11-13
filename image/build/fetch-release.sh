#!/usr/bin/env bash
# Download a release asset and install it only if it matches the pinned
# sha256 AND its detached signature (<url>.asc) verifies against the pinned
# release key. Used by the Containerfile's fetch stage.
#
#   fetch-release.sh URL SHA256 ARMORED_PUBKEY OUTPUT
set -euo pipefail

url="$1"
sha256="$2"
pubkey="$3"
output="$4"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl -fsSL --retry 3 -o "${work}/asset" "${url}"
curl -fsSL --retry 3 -o "${work}/asset.asc" "${url}.asc"

echo "${sha256}  ${work}/asset" | sha256sum --check --quiet \
  || { echo "checksum mismatch for ${url}" >&2; exit 1; }

gpg --batch --quiet --dearmor -o "${work}/keyring.gpg" < "${pubkey}"
gpgv --quiet --keyring "${work}/keyring.gpg" "${work}/asset.asc" "${work}/asset" \
  || { echo "signature verification failed for ${url}" >&2; exit 1; }

install -m 0755 "${work}/asset" "${output}"
echo "verified ${url}"
