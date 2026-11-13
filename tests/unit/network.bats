#!/usr/bin/env bats
# Uplink NIC: the RTL8125 runs with a single receive queue under r8169, so
# receive processing is spread over the CPUs in software (RPS). Operator
# diagnostics ship in the image: ethtool for the link, top/htop/atop for load.

load helpers

LINK="${ROOTFS}/usr/lib/systemd/network/10-gvpn-exit-lan0.link"

@test "lan0 steers received packets to every CPU" {
  grep -qx 'ReceivePacketSteeringCPUMask=all' "${LINK}"
}

@test "the image sets 4 MiB receive and send defaults as well as maxima" {
  local setting
  # Maxima alone do not enlarge hoprd's inherited QUIC socket buffers.
  for setting in rmem_default rmem_max wmem_default wmem_max; do
    awk -v key="net.core.${setting}" '
      $1 == key && $2 == "=" { value = $3 }
      END { exit !(value == 4194304) }
    ' "${ROOTFS}/usr/lib/sysctl.d/90-gvpn-exit.conf"
  done
}

@test "the image installs the operator diagnostics" {
  local packages
  packages="$(sed -n '/dnf -y install --setopt=install_weak_deps=False/,/dnf clean all/p' "${REPO_ROOT}/image/Containerfile")"
  for pkg in ethtool procps-ng htop atop; do
    grep -qw -- "${pkg}" <<< "${packages}" || { echo "missing ${pkg}"; false; }
  done
}

@test "atop's log directory is created by tmpfiles, not shipped in /var" {
  grep -qx 'd /var/log/atop 0755 root root -' "${ROOTFS}/usr/lib/tmpfiles.d/gvpn-exit.conf"
}
