#!/usr/bin/env bats
# The image's package set: Fedora's updates are applied when the image is
# built.

load helpers

CONTAINERFILE="${REPO_ROOT}/image/Containerfile"

# The final stage, the OS image itself.
os_stage() {
  awk 'found; /^FROM \$\{FEDORA_IOT_IMAGE\}$/ { found = 1 }' "${CONTAINERFILE}"
}

@test "Fedora's updates are applied before the image's packages are installed" {
  local upgrade install
  upgrade="$(os_stage | grep -n 'dnf -y upgrade' | cut -d: -f1)"
  install="$(os_stage | grep -n 'dnf -y install ' | cut -d: -f1)"
  [ -n "${upgrade}" ]
  [ -n "${install}" ]
  (( upgrade < install ))
}
