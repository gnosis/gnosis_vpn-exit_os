#!/usr/bin/env bats
# CPU frequency policy: the image runs every cpufreq policy with the
# performance governor. Applied by systemd-tmpfiles at boot; exercised here
# against a fake sysfs tree.

load helpers

CONF="${ROOTFS}/usr/lib/tmpfiles.d/gvpn-exit-cpu.conf"

setup() {
  setup_sandbox
  # The image applies this policy with systemd-tmpfiles, which only exists on
  # Linux; the Linux devshell and CI exercise it.
  [[ "$(uname -s)" == Linux ]] || skip "systemd-tmpfiles is Linux-only"
  CPUFREQ="${SANDBOX}/sys/devices/system/cpu/cpufreq"
  for policy in policy0 policy1 policy15; do
    mkdir -p "${CPUFREQ}/${policy}"
    echo powersave > "${CPUFREQ}/${policy}/scaling_governor"
  done
}

teardown() {
  teardown_sandbox
}

@test "every cpufreq policy gets the performance governor" {
  run systemd-tmpfiles --root="${SANDBOX}" --create "${CONF}"
  [ "${status}" -eq 0 ]
  for policy in policy0 policy1 policy15; do
    [ "$(cat "${CPUFREQ}/${policy}/scaling_governor")" = performance ]
  done
}

@test "a machine without cpufreq is left alone" {
  rm -rf "${SANDBOX}/sys"
  run systemd-tmpfiles --root="${SANDBOX}" --create "${CONF}"
  [ "${status}" -eq 0 ]
  [ ! -e "${SANDBOX}/sys/devices/system/cpu/cpufreq" ]
}
