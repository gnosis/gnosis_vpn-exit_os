#!/usr/bin/env bash
# gvpn-exit-account-migrate.service: rename the administrator account of a
# device installed before it was called `gvpn`, before sshd and the console
# accept logins. Devices installed from earlier ISOs have `devops`, and this
# image's sshd and sudo admit `gvpn` only.
#
# The account keeps its uid, password, keys and wheel membership. Its home
# moves to the new name and the old path stays as a link to it: the previous
# deployment, which greenboot rolls back to, keeps its own /etc with `devops`
# and that home, while /var is shared. A device without `devops` is left
# alone, so this runs on every boot and does its work once.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

ACCOUNTS_DIR="${GVPN_ACCOUNTS_DIR:-/etc}"
OLD=devops
NEW=gvpn

main() {
  local entry old_home new_home ids
  entry="$(getent passwd "${OLD}")" || return 0
  if getent passwd "${NEW}" >/dev/null; then
    log "both ${OLD} and ${NEW} exist; renaming neither"
    return 1
  fi
  old_home="$(cut -d: -f6 <<< "${entry}")"
  new_home="$(dirname "${old_home}")/${NEW}"

  # The home moves first, so the old account still reaches its keys through
  # the link if the rename below fails. A link left by an earlier boot means
  # the home has moved already.
  if [[ -d "${old_home}" && ! -L "${old_home}" ]]; then
    if [[ -e "${new_home}" ]]; then
      log "${new_home} exists already; not moving ${old_home} onto it"
      return 1
    fi
    mv "${old_home}" "${new_home}"
    ln -s "${NEW}" "${old_home}"
  fi

  usermod -l "${NEW}" -d "${new_home}" "${OLD}"
  if getent group "${OLD}" >/dev/null; then
    groupmod -n "${NEW}" "${OLD}"
  fi
  # usermod leaves the subordinate id ranges, where the device has any, under
  # the old name.
  for ids in "${ACCOUNTS_DIR}/subuid" "${ACCOUNTS_DIR}/subgid"; do
    [[ -f "${ids}" ]] && sed -i "s/^${OLD}:/${NEW}:/" "${ids}"
  done
  log "renamed ${OLD} to ${NEW}, home ${new_home}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
