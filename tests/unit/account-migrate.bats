#!/usr/bin/env bats
# account-migrate.sh renames the administrator account of a device installed
# before it was called `gvpn`. The image's sshd and sudo admit `gvpn` only, so
# a device that updates with `devops` left would lock its operators out; the
# previous deployment, which greenboot rolls back to, still knows the account
# as `devops`.

load helpers

SCRIPT="${LIBEXEC}/account-migrate.sh"

setup() {
  setup_sandbox
  export GVPN_ACCOUNTS_DIR="${SANDBOX}/etc"
  HOME_ROOT="${SANDBOX}/home"
  # The accounts that exist, one file each: getent reads them.
  ACCOUNTS="${SANDBOX}/accounts"
  mkdir -p "${ACCOUNTS}" "${HOME_ROOT}/devops/.ssh"
  export ACCOUNTS HOME_ROOT
  echo 'ssh-ed25519 AAAAoperator1 ops@laptop' >"${HOME_ROOT}/devops/.ssh/authorized_keys"
  echo "devops:x:1000:1000::${HOME_ROOT}/devops:/bin/bash" >"${ACCOUNTS}/passwd.devops"
  echo 'devops:x:1000:' >"${ACCOUNTS}/group.devops"
  # A device's /etc/shadow, with Fedora's own operator system account.
  cat >"${GVPN_ACCOUNTS_DIR}/shadow" <<'EOF'
root:!::0:99999:7:::
operator:*::0:99999:7:::
devops:$6$salt$hash:20771:0:99999:7:::
EOF
  printf 'devops:524288:65536\n' >"${GVPN_ACCOUNTS_DIR}/subuid"
  printf 'devops:524288:65536\n' >"${GVPN_ACCOUNTS_DIR}/subgid"
  mock_cmd getent 'cat "${ACCOUNTS}/$1.$2" 2>/dev/null'
  # usermod refuses a new name that /etc/shadow already has, as shadow-utils
  # does, and otherwise renames the account.
  mock_cmd usermod '
if grep -q "^$2:" "${GVPN_ACCOUNTS_DIR}/shadow"; then
  echo "usermod: user '\''$2'\'' already exists in /etc/shadow" >&2
  exit 1
fi
sed -i "s/^$5:/$2:/" "${GVPN_ACCOUNTS_DIR}/shadow"
mv "${ACCOUNTS}/passwd.$5" "${ACCOUNTS}/passwd.$2"'
  mock_cmd groupmod 'mv "${ACCOUNTS}/group.$3" "${ACCOUNTS}/group.$2"'
}

teardown() {
  teardown_sandbox
}

@test "renames devops to gvpn with its group, password and keys" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx "usermod -l gvpn -d ${HOME_ROOT}/gvpn devops" "${MOCK_LOG}"
  grep -qx 'groupmod -n gvpn devops' "${MOCK_LOG}"
  grep -qx 'gvpn:$6$salt$hash:20771:0:99999:7:::' "${GVPN_ACCOUNTS_DIR}/shadow"
  grep -qx 'ssh-ed25519 AAAAoperator1 ops@laptop' "${HOME_ROOT}/gvpn/.ssh/authorized_keys"
  # Fedora's operator system account is none of this script's business.
  grep -qxF 'operator:*::0:99999:7:::' "${GVPN_ACCOUNTS_DIR}/shadow"
}

@test "a device without subordinate id files is renamed all the same" {
  rm "${GVPN_ACCOUNTS_DIR}/subuid" "${GVPN_ACCOUNTS_DIR}/subgid"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx 'groupmod -n gvpn devops' "${MOCK_LOG}"
  [ ! -e "${GVPN_ACCOUNTS_DIR}/subuid" ]
}

@test "the subordinate id ranges follow the account" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx 'gvpn:524288:65536' "${GVPN_ACCOUNTS_DIR}/subuid"
  grep -qx 'gvpn:524288:65536' "${GVPN_ACCOUNTS_DIR}/subgid"
}

# A rollback boots the previous deployment, whose /etc still has devops with
# its old home; /var, and the home in it, is shared by both.
@test "the old home path stays a link to the moved home for the previous deployment" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ -L "${HOME_ROOT}/devops" ]
  [ "$(readlink "${HOME_ROOT}/devops")" = "gvpn" ]
  [ -d "${HOME_ROOT}/gvpn" ] && [ ! -L "${HOME_ROOT}/gvpn" ]
  grep -qx 'ssh-ed25519 AAAAoperator1 ops@laptop' "${HOME_ROOT}/devops/.ssh/authorized_keys"
}

@test "a device installed as gvpn is left alone" {
  rm "${ACCOUNTS}/passwd.devops" "${ACCOUNTS}/group.devops"
  echo "gvpn:x:1000:1000::${HOME_ROOT}/gvpn:/bin/bash" >"${ACCOUNTS}/passwd.gvpn"
  cp "${GVPN_ACCOUNTS_DIR}/shadow" "${SANDBOX}/shadow.before"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  ! grep -q '^usermod\|^groupmod' "${MOCK_LOG}"
  cmp "${SANDBOX}/shadow.before" "${GVPN_ACCOUNTS_DIR}/shadow"
  [ -d "${HOME_ROOT}/devops" ] && [ ! -L "${HOME_ROOT}/devops" ]
}

# After a rollback, the next update deploys from the devops /etc again, while
# the home already moved on the first try.
@test "a home moved on an earlier boot is renamed without moving it again" {
  mv "${HOME_ROOT}/devops" "${HOME_ROOT}/gvpn"
  ln -s gvpn "${HOME_ROOT}/devops"
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  grep -qx "usermod -l gvpn -d ${HOME_ROOT}/gvpn devops" "${MOCK_LOG}"
  [ "$(readlink "${HOME_ROOT}/devops")" = "gvpn" ]
  grep -qx 'ssh-ed25519 AAAAoperator1 ops@laptop' "${HOME_ROOT}/gvpn/.ssh/authorized_keys"
}

@test "refuses to touch either account when both exist" {
  echo "gvpn:x:1001:1001::${HOME_ROOT}/gvpn:/bin/bash" >"${ACCOUNTS}/passwd.gvpn"
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"both devops and gvpn exist"* ]]
  ! grep -q '^usermod\|^groupmod' "${MOCK_LOG}"
  [ -d "${HOME_ROOT}/devops" ] && [ ! -L "${HOME_ROOT}/devops" ]
}

@test "refuses to move the home onto an existing directory" {
  mkdir -p "${HOME_ROOT}/gvpn"
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  ! grep -q '^usermod' "${MOCK_LOG}"
  [ -f "${HOME_ROOT}/devops/.ssh/authorized_keys" ]
}

@test "a failed rename fails the unit, and devops still reaches its keys" {
  mock_cmd usermod 'exit 1'
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  grep -qx 'ssh-ed25519 AAAAoperator1 ops@laptop' "${HOME_ROOT}/devops/.ssh/authorized_keys"
}
