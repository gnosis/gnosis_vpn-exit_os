#!/usr/bin/env bats
# Exercise the ISO recipe with container workloads replaced by local fixtures.

load helpers

setup() {
  setup_sandbox
  export GVPN_IMAGE_REPO="registry.example.org:5443/fleet/exit-os"
  export WORK="${SANDBOX}/repo"
  export IMAGE_ROOT="${SANDBOX}/image"
  export ORIGIN="${SANDBOX}/origin"
  mkdir -p "${WORK}"
  cp -a "${REPO_ROOT}/tools" "${REPO_ROOT}/image" "${REPO_ROOT}/keys" "${REPO_ROOT}/justfile" "${WORK}/"
  ssh-keygen -q -t ed25519 -N '' -f "${SANDBOX}/enroll"
  export GVPN_DEVOPS_SSH_KEY="${SANDBOX}/enroll.pub"
  export GVPN_ENROLL_KEY="${SANDBOX}/enroll"
  export GVPN_BASTION="support@bastion.example.org"
  export GVPN_SUPPORT_PORT=22001
  export GVPN_BASTION_KNOWN_HOSTS="${SANDBOX}/known_hosts"
  echo 'bastion.example.org ssh-ed25519 AAAA' > "${GVPN_BASTION_KNOWN_HOSTS}"
  # The image-update public key is a build input, not a repository file.
  export GVPN_COSIGN_PUB="${SANDBOX}/cosign.pub"
  write_public_key "${GVPN_COSIGN_PUB}"
  mock_cmd git 'echo test-version'
  mock_cmd id 'case "$1" in -u|-g) echo 1000 ;; esac'
  mock_cmd chown
  mock_cmd docker '
shift
env_args=()
while (( $# > 0 )); do
  case "$1" in
    -e)
      if [[ "$2" == *=* ]]; then
        env_args+=("$2")
      else
        env_args+=("$2=${!2-}")
      fi
      shift 2 ;;
    -v|-w) shift 2 ;;
    --rm|--privileged|--network=host|-it) shift ;;
    *)
      # The image the builder container is started from.
      printf "%s\n" "$1" > "${SANDBOX}/docker-image"
      shift; break ;;
  esac
done
env -u GVPN_IMAGE_REPO "${env_args[@]}" "$@"'
  mock_cmd podman '
case "$1" in
  build)
    shift
    env_args=()
    while (( $# > 0 )); do
      if [[ "$1" == --build-arg ]]; then
        env_args+=("$2"); shift 2
      else
        shift
      fi
    done
    cp -a "${WORK}/image/rootfs" "${IMAGE_ROOT}"
    env -u GVPN_IMAGE_REPO "${env_args[@]}" bash "${WORK}/image/build/configure-image.sh" "${IMAGE_ROOT}" ;;
  tag) printf "%s\n" "$3" > "${ORIGIN}" ;;
  # podman image inspect: the image ID and the version label of the built image.
  image) echo "sha256:1d1d1d label-version" ;;
  run)
    # bootc-image-builder writes its manifest next to the disk image.
    mkdir -p output/iso
    printf "{\"kickstart\": \"%%post -- curl enroll.key\"}\n" > output/iso/manifest-anaconda-iso.json
    [[ -e "${SANDBOX}/bib-fail" ]] && exit 1
    for arg in "$@"; do
      [[ "${arg}" == *:/config.toml:ro ]] && cp "${arg%%:/config.toml:ro}" "${SANDBOX}/bib-config.toml"
    done
    touch output/iso/install.iso
    [[ "${*: -1}" == "$(cat "${ORIGIN}")" ]] ;;
esac'
}

teardown() {
  teardown_sandbox
}

@test "iso carries deployment inputs through Docker, image rendering and the disk origin" {
  run just --justfile "${WORK}/justfile" channel=stable iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${ORIGIN}")" = "${GVPN_IMAGE_REPO}:stable" ]
  jq -e --arg repo "${GVPN_IMAGE_REPO}" '.transports.docker | keys == [$repo]' "${IMAGE_ROOT}/etc/containers/policy.json"
  cmp "${ROOTFS}/etc/containers/policy.json" "${WORK}/image/rootfs/etc/containers/policy.json"
  cmp "${SHARE}/hoprd.cfg.yaml" "${WORK}/image/rootfs/usr/share/gvpn-exit/hoprd.cfg.yaml"
}

@test "the builder runs a pinned, immutable podman image" {
  # A floating tag silently changes the build toolchain, and a pinned digest of
  # a moving tag is garbage-collected by quay once the tag moves on: the pin is
  # an immutable tag and the digest behind it.
  run just --justfile "${WORK}/justfile" channel=stable iso
  [ "${status}" -eq 0 ]
  [[ "$(cat "${SANDBOX}/docker-image")" =~ ^quay\.io/podman/stable:v[0-9.]+-immutable@sha256:[0-9a-f]{64}$ ]]
}

@test "iso refuses missing deployment inputs before building an image" {
  run env -u GVPN_IMAGE_REPO just --justfile "${WORK}/justfile" iso
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_IMAGE_REPO"* ]]
  [ ! -e "${IMAGE_ROOT}" ]
}

@test "iso builds without bastion inputs for a device administered from its LAN" {
  run env -u GVPN_BASTION -u GVPN_SUPPORT_PORT -u GVPN_ENROLL_KEY -u GVPN_BASTION_KNOWN_HOSTS \
    just --justfile "${WORK}/justfile" iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${ORIGIN}")" = "${GVPN_IMAGE_REPO}:canary" ]
}

# The manifest embeds the kickstart the disk was built with, so an ISO built
# with the bastion inputs leaves the enrollment private key in it at 0644.
@test "the bootc-image-builder manifest is removed from the output directory" {
  run just --justfile "${WORK}/justfile" channel=stable iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  [ -e "${WORK}/output/iso/install.iso" ]
  [ ! -e "${WORK}/output/iso/manifest-anaconda-iso.json" ]
}

@test "the bootc-image-builder manifest is removed also when the disk build fails" {
  touch "${SANDBOX}/bib-fail"
  run just --justfile "${WORK}/justfile" channel=stable iso
  echo "${output}"
  [ "${status}" -ne 0 ]
  [ ! -e "${WORK}/output/iso/manifest-anaconda-iso.json" ]
}

# The installer tags the image with the channel the device then tracks, so a
# misspelt channel installs a device that never sees an update.
@test "iso refuses a channel that is not canary or stable" {
  run just --justfile "${WORK}/justfile" channel=stabel iso
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"stabel"* ]]
  [ ! -e "${ORIGIN}" ]
}

# One installer serves hardware and an Incus VM: by default it picks the only
# internal disk at install time instead of pinning a kernel disk name.
@test "iso detects its install disk at install time by default" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  run just --justfile "${WORK}/justfile" iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -qF '%include /tmp/gvpn-install-disk.ks' "${SANDBOX}/bib-config.toml"
  run grep -q 'ignoredisk --only-use=nvme0n1' "${SANDBOX}/bib-config.toml"
  [ "${status}" -eq 1 ]
  grep -qx 'disk=auto' "${WORK}/output/iso/install.iso.target"
  grep -qx 'enrollment=none' "${WORK}/output/iso/install.iso.target"
  grep -qx 'access=key' "${WORK}/output/iso/install.iso.target"
  # The version is the label of the image the ISO embeds, not the checkout's.
  grep -qx 'label-version' "${WORK}/output/iso/install.iso.version"
  grep -qx 'image=sha256:1d1d1d' "${WORK}/output/iso/install.iso.target"
  grep -qx "sha256=$(sha256sum "${WORK}/output/iso/install.iso" | cut -d' ' -f1)" "${WORK}/output/iso/install.iso.target"
}

@test "an empty GVPN_INSTALL_DISK detects the disk like an unset one" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  GVPN_INSTALL_DISK="" run just --justfile "${WORK}/justfile" iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -qF '%include /tmp/gvpn-install-disk.ks' "${SANDBOX}/bib-config.toml"
  grep -qx 'disk=auto' "${WORK}/output/iso/install.iso.target"
}

# The sidecars are what publish-iso trusts about the ISO beside them: a build
# that stops early must not leave the description of an earlier ISO.
@test "a failed disk build leaves no sidecar of an earlier ISO" {
  mkdir -p "${WORK}/output/iso"
  echo 1.0.0 > "${WORK}/output/iso/install.iso.version"
  { echo disk=auto; echo enrollment=none; echo access=console; } > "${WORK}/output/iso/install.iso.target"
  touch "${SANDBOX}/bib-fail"
  run just --justfile "${WORK}/justfile" iso
  [ "${status}" -ne 0 ]
  [ ! -e "${WORK}/output/iso/install.iso.version" ]
  [ ! -e "${WORK}/output/iso/install.iso.target" ]
}

@test "iso refuses an image without a version label" {
  mock_cmd podman 'case "$1" in image) echo "sha256:1d1d1d " ;; esac'
  run just --justfile "${WORK}/justfile" iso-console-only
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no version label"* ]]
  [ ! -e "${WORK}/output/iso/install.iso" ]
}

@test "GVPN_INSTALL_DISK pins the kickstart to the named disk" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  GVPN_INSTALL_DISK=sda run just --justfile "${WORK}/justfile" iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -q 'ignoredisk --only-use=sda' "${SANDBOX}/bib-config.toml"
  grep -q -- '--drives=sda' "${SANDBOX}/bib-config.toml"
  grep -qx 'disk=sda' "${WORK}/output/iso/install.iso.target"
}

@test "iso with the bastion inputs records a managed installer" {
  run just --justfile "${WORK}/justfile" iso
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -qx 'enrollment=bastion' "${WORK}/output/iso/install.iso.target"
  grep -qx 'access=key' "${WORK}/output/iso/install.iso.target"
}

@test "iso-console leaves no installer SSH key and targets the console path" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  run just --justfile "${WORK}/justfile" iso-console
  echo "${output}"
  [ "${status}" -eq 0 ]
  grep -qx 'disk=auto' "${WORK}/output/iso/install.iso.target"
  grep -qx 'access=console' "${WORK}/output/iso/install.iso.target"
  grep -q 'user --name=devops --groups=wheel --iscrypted --password' "${SANDBOX}/bib-config.toml"
  run grep -q 'sshkey --username=devops' "${SANDBOX}/bib-config.toml"
  [ "${status}" -eq 1 ]
  grep -q 'chage -d 0 devops' "${SANDBOX}/bib-config.toml"
  grep -q 'systemctl enable serial-getty@ttyS0.service' "${SANDBOX}/bib-config.toml"
}

@test "the Incus-only ISO recipes are gone" {
  run just --justfile "${WORK}/justfile" incus-iso
  [ "${status}" -ne 0 ]
  run just --justfile "${WORK}/justfile" incus-iso-console
  [ "${status}" -ne 0 ]
}

@test "iso refuses a private key as the update public key" {
  { echo '-----BEGIN PRIVATE KEY-----'; echo '-----END PRIVATE KEY-----'; } > "${GVPN_COSIGN_PUB}"
  run just --justfile "${WORK}/justfile" iso
  echo "${output}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_COSIGN_PUB"* ]]
  [ ! -e "${IMAGE_ROOT}" ]
  [ ! -e "${SANDBOX}/docker-image" ]
}
