#!/usr/bin/env bats
# tools/build-disk.sh sources its helpers from its own directory, so a run
# started elsewhere through a relative path still finds them.

load helpers

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "build-disk resolves its helpers when started through a relative path" {
  mkdir -p "${SANDBOX}/repo/tools" "${SANDBOX}/repo/image"
  cp "${REPO_ROOT}/tools/build-disk.sh" "${REPO_ROOT}/tools/lib.sh" "${SANDBOX}/repo/tools/"
  cp "${REPO_ROOT}/image/versions.env" "${SANDBOX}/repo/image/"

  # A channel the script refuses, checked after both helpers are sourced, so
  # its message proves the run got past them.
  run bash -c "cd '${SANDBOX}' && bash repo/tools/build-disk.sh iso config.toml stabel"

  [ "${status}" -eq 64 ]
  [[ "${output}" == *"invalid channel 'stabel'"* ]]
}

# The ISO built with the bastion inputs carries the enrollment private key, so
# only its owner may read it; a LAN-only ISO carries no secret.
@test "build-disk leaves an ISO that carries the enrollment key readable by its owner only" {
  mkdir -p "${SANDBOX}/repo/tools" "${SANDBOX}/repo/image/bib" "${SANDBOX}/repo/output"
  cp "${REPO_ROOT}/tools/build-disk.sh" "${REPO_ROOT}/tools/lib.sh" "${REPO_ROOT}/tools/render-bib-config.sh" "${SANDBOX}/repo/tools/"
  cp "${REPO_ROOT}/image/versions.env" "${SANDBOX}/repo/image/"
  cp "${REPO_ROOT}/image/bib/iso.toml.in" "${SANDBOX}/repo/image/bib/"
  echo "ssh-ed25519 AAAAC3NzaDevops ops@example" > "${SANDBOX}/devops.pub"
  ssh-keygen -q -t ed25519 -N '' -f "${SANDBOX}/enroll"
  echo "bastion.example ssh-ed25519 AAAAC3NzaBastion" > "${SANDBOX}/known_hosts"
  # bootc-image-builder writes the ISO world-readable into the /output mount.
  mock_cmd podman '
[[ "$1" == image ]] && echo "sha256:1d1d1d 1.2.3"
for arg in "$@"; do
  if [[ "${arg}" == *:/output ]]; then
    mkdir -p "${arg%:/output}/bootiso"
    echo iso > "${arg%:/output}/bootiso/install.iso"
    chmod 0644 "${arg%:/output}/bootiso/install.iso"
  fi
done'
  export GVPN_IMAGE_REPO=registry.example.org/fleet/gvpn-exit-os
  unset GVPN_CONSOLE_ACCESS GVPN_INSTALL_DISK
  iso="${SANDBOX}/repo/output/iso/bootiso/install.iso"

  GVPN_BASTION=support@bastion.example GVPN_SUPPORT_PORT=22001 \
    GVPN_ENROLL_KEY="${SANDBOX}/enroll" GVPN_BASTION_KNOWN_HOSTS="${SANDBOX}/known_hosts" \
    "${SANDBOX}/repo/tools/render-bib-config.sh" iso "${SANDBOX}/devops.pub" > "${SANDBOX}/repo/output/bastion.toml"
  run bash -c "cd '${SANDBOX}/repo' && tools/build-disk.sh iso output/bastion.toml"
  [ "${status}" -eq 0 ]
  [ "$(stat -c %a "${iso}")" = "600" ]
  grep -qx 'enrollment=bastion' "${iso}.target"

  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  "${SANDBOX}/repo/tools/render-bib-config.sh" iso "${SANDBOX}/devops.pub" > "${SANDBOX}/repo/output/lan.toml"
  run bash -c "cd '${SANDBOX}/repo' && tools/build-disk.sh iso output/lan.toml"
  [ "${status}" -eq 0 ]
  [ "$(stat -c %a "${iso}")" = "644" ]
  grep -qx 'enrollment=none' "${iso}.target"
  grep -qx 'access=key' "${iso}.target"
  grep -qx '1.2.3' "${iso}.version"
}
