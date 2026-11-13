#!/usr/bin/env bash
# Build the recovery stick image with the pinned base image.
# Runs inside tools/builder.sh (rootful podman), like tools/build-image.sh.
#
#   tools/build-recovery.sh
#
# Result: output/recovery/{BOOTX64.EFI,SHA256SUMS,build.txt}. The byte budget
# lives in image/recovery/versions.env; tools/recovery-usb.sh refuses an image
# that does not match SHA256SUMS. GVPN_RECOVERY_OUTPUT overrides the directory
# (tests).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=SCRIPTDIR/../image/versions.env
source image/versions.env
# shellcheck source=SCRIPTDIR/../image/recovery/versions.env
source image/recovery/versions.env

out="${GVPN_RECOVERY_OUTPUT:-${PWD}/output/recovery}"
mkdir -p "${out}"

# Appliances are x86_64 and the stick boots BOOTX64.EFI, so the kernel, the
# initrd and the EFI stub must be amd64 whatever this host is; an arm64 host
# (Docker on a Mac) runs it emulated. The build installs packages into the
# container's own filesystem and writes one file to /out, so it needs neither
# privilege nor the host's container storage; the repository is mounted
# read-only.
podman run --rm --pull=missing --platform linux/amd64 \
  --security-opt label=type:unconfined_t \
  -v "${PWD}:/src:ro" \
  -v "${out}:/out" \
  -e GVPN_RECOVERY_MAX_BYTES="${RECOVERY_MAX_BYTES}" \
  "${FEDORA_IOT_IMAGE}" \
  /src/image/recovery/build.sh /out

if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  chown -R "${HOST_UID}:${HOST_GID}" "${out}"
fi
ls -l "${out}/BOOTX64.EFI"
