#!/usr/bin/env bats
# The local console (tty1 on hardware, the VM consoles) is where an operator
# logs in first. Kernel messages printed there bury the login prompt and run
# through the session: without auditd every audit record, one for each sudo
# and each unit start or stop, reaches the console at the default log level.
# The boot menu and the login prompt name the appliance, not the Fedora it is
# built on.

load helpers

BRAND="${REPO_ROOT}/image/build/brand-os-release.sh"

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

# The base image's /usr/lib/os-release, abridged.
fedora_os_release() {
  cat <<'EOF'
NAME="Fedora Linux"
VERSION="44 (IoT Edition)"
ID=fedora
VERSION_ID=44
PRETTY_NAME="Fedora Linux 44 (IoT Edition)"
CPE_NAME="cpe:/o:fedoraproject:fedora:44"
VARIANT="IoT Edition"
VARIANT_ID=iot
EOF
}

@test "the device is named gvpn-exit until /etc/hostname names it" {
  # The initrd sets localhost and systemd keeps a hostname that is already set,
  # so DEFAULT_HOSTNAME in os-release never applies. The system.hostname
  # credential does: systemd uses it, in the initrd too, whenever /etc/hostname
  # names no host, and `hostnamectl hostname NAME` still renames the device.
  grep -qx 'kargs = \["systemd\.set_credential=system\.hostname:gvpn-exit"\]' \
    "${ROOTFS}/usr/lib/bootc/kargs.d/00-gvpn-exit.toml"
}

@test "the boot menus say GnosisVPN ExitOS and the OS stays Fedora underneath" {
  fedora_os_release > "${SANDBOX}/os-release"
  run bash "${BRAND}" "${SANDBOX}/os-release"
  [ "${status}" -eq 0 ]
  (
    # shellcheck source=/dev/null
    . "${SANDBOX}/os-release"
    # ostree titles boot entries with PRETTY_NAME, bootc-image-builder titles
    # the installer menu with NAME.
    [ "${PRETTY_NAME}" = "GnosisVPN ExitOS" ]
    [ "${NAME}" = "GnosisVPN ExitOS" ]
    # dnf, bootc-image-builder and the installer's volume label key on these.
    [ "${ID}" = "fedora" ]
    [ "${VERSION_ID}" = "44" ]
    [ "${VARIANT_ID}" = "iot" ]
    [ "${VERSION}" = "44 (IoT Edition)" ]
  )
  [ "$(wc -l < "${SANDBOX}/os-release")" -eq "$(fedora_os_release | wc -l)" ]
}

@test "branding stops the build when os-release has no name to replace" {
  fedora_os_release | grep -v '^PRETTY_NAME=' > "${SANDBOX}/os-release"
  run bash "${BRAND}" "${SANDBOX}/os-release"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"PRETTY_NAME"* ]]
}

@test "only critical kernel messages reach the console" {
  awk '
    $1 == "kernel.printk" && $2 == "=" { level = $3; fields = NF - 2 }
    END { exit !(level == 3 && fields == 4) }
  ' "${ROOTFS}/usr/lib/sysctl.d/90-gvpn-exit.conf"
}
