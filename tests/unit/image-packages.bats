#!/usr/bin/env bats
# The image's package set: Fedora's updates are applied when the image is
# built, the unused CNI plugins are removed, and node_exporter is Fedora's
# source package rebuilt with the Go toolchain of the build, because the
# repository build carries an older Go's vulnerable standard library.

load helpers

CONTAINERFILE="${REPO_ROOT}/image/Containerfile"

# The final stage, the OS image itself.
os_stage() {
  awk 'found; /^FROM \$\{FEDORA_IOT_IMAGE\}$/ { found = 1 }' "${CONTAINERFILE}"
}

# The packages the OS stage installs, one word per line.
installed_packages() {
  os_stage | sed -n '/dnf -y install /,/dnf -y remove/p' | tr -s ' \\"' '\n'
}

@test "Fedora's updates are applied before the image's packages are installed" {
  local upgrade install
  upgrade="$(os_stage | grep -n 'dnf -y upgrade' | cut -d: -f1)"
  install="$(os_stage | grep -n 'dnf -y install ' | cut -d: -f1)"
  [ -n "${upgrade}" ]
  [ -n "${install}" ]
  (( upgrade < install ))
}

@test "the CNI plugins are removed" {
  os_stage | grep -E 'dnf -y remove( [a-z-]+)* containernetworking-plugins( |$)'
}

@test "node_exporter is Fedora's source package rebuilt in the build, not the repository build" {
  [ "$(installed_packages | grep -cx 'node-exporter')" -eq 0 ]
  installed_packages | grep -qx '/rebuilt/node-exporter-\*\.rpm'
  grep -Eq '^NODE_EXPORTER_SRPM_SHA256=[0-9a-f]{64}$' "${REPO_ROOT}/image/versions.env"
  grep -q 'NODE_EXPORTER_SRPM_SHA256}  /tmp/node-exporter.src.rpm" | sha256sum --check' "${CONTAINERFILE}"
}
