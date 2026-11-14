#!/usr/bin/env bash
# Name the OS GnosisVPN ExitOS in the image's os-release. ostree titles the boot
# menu entries with PRETTY_NAME, bootc-image-builder titles the installer's menu
# with NAME. ID, VERSION_ID and the other fields stay Fedora's: dnf,
# bootc-image-builder and the installer's volume label key on them.
#
#   brand-os-release.sh [OS_RELEASE]   (default /usr/lib/os-release)
set -euo pipefail

os_release="${1:-/usr/lib/os-release}"
name="GnosisVPN ExitOS"

for field in NAME PRETTY_NAME; do
  if ! grep -q "^${field}=" "${os_release}"; then
    echo "${os_release} has no ${field} to replace" >&2
    exit 1
  fi
done
sed -i \
  -e "s/^NAME=.*/NAME=\"${name}\"/" \
  -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"${name}\"/" \
  "${os_release}"
