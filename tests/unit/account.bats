#!/usr/bin/env bats
# The installer creates one administrator account, `gvpn`, and SSH and sudo
# admit that account only. A name that differs in one place locks the
# operator out.

load helpers

@test "SSH and sudo admit the account the installer creates" {
  run env -u GVPN_BASTION -u GVPN_SUPPORT_PORT -u GVPN_ENROLL_KEY -u GVPN_BASTION_KNOWN_HOSTS \
    GVPN_CONSOLE_ACCESS=1 "${REPO_ROOT}/tools/render-bib-config.sh" iso /dev/null
  [ "${status}" -eq 0 ]
  grep -q '^user --name=gvpn ' <<< "${output}"
  [ "$(awk '$1 == "AllowUsers" { $1 = ""; print substr($0, 2) }' "${ROOTFS}/etc/ssh/sshd_config.d/40-gvpn-exit.conf")" = "gvpn" ]
  [ "$(grep -v '^#' "${ROOTFS}/etc/sudoers.d/90-gvpn-exit")" = "gvpn ALL=(ALL) NOPASSWD: ALL" ]
}
