#!/usr/bin/env bats
# Every shipped script passes shellcheck and is executable; shared helpers
# are sourced only.

load helpers

# The same command the recipe runs, so the suite cannot drift from it (it used
# to skip tests/integration/).
@test "shellcheck passes on every shipped and build script" {
  run bash -c "cd '${REPO_ROOT}' && just lint"
  echo "${output}"
  [ "${status}" -eq 0 ]
}

@test "scripts are executable, sourced libraries are not" {
  for f in "${LIBEXEC}"/*.sh "${ROOTFS}"/usr/bin/* "${ROOTFS}"/usr/lib/greenboot/check/*/*.sh \
      "${ROOTFS}"/usr/lib/greenboot/*.d/*.sh "${ROOTFS}"/usr/lib/NetworkManager/dispatcher.d/*; do
    case "$(basename "${f}")" in
      lib.sh|checks.sh|public-ip.sh) [ ! -x "${f}" ] || { echo "${f} should not be executable"; false; } ;;
      *) [ -x "${f}" ] || { echo "${f} is not executable"; false; } ;;
    esac
  done
}
