#!/usr/bin/env bash
# Throwaway support bastion for the integration tests: an unprivileged sshd on
# the host, which a QEMU guest reaches as 10.0.2.2 (slirp) and an Incus guest
# as the bridge's host address. Device keys get the same restriction as on the
# real bastion, so a device can only open its own reverse port. The reverse
# port lands on the host's loopback, which makes the device reachable as
# `ssh -p SUPPORT_PORT devops@127.0.0.1`. Keys, config and logs live in
# output/bastion.
#
#   tests/integration/bastion.sh start         create keys on first use, start sshd
#   tests/integration/bastion.sh env           print the `just iso` inputs
#   tests/integration/bastion.sh allow KEY     admit a device public key line
#   tests/integration/bastion.sh stop
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
DIR="${PWD}/output/bastion"
BASTION_PORT="${BASTION_PORT:-2200}"
SUPPORT_PORT="${GVPN_SUPPORT_PORT:-22001}"
# How the guest reaches the host. QEMU user networking uses 10.0.2.2; an
# Incus guest uses the bridge's host address, so both are inputs. The bastion
# listens on the workstation's loopback by default; an Incus guest needs the
# bridge address too (BASTION_LISTEN_ADDR).
GUEST_HOST_ADDR="${BASTION_ADDRESS:-10.0.2.2}"
LISTEN_ADDR="${BASTION_LISTEN_ADDR:-127.0.0.1}"

allow() {
  local key="$1"
  [[ "${key}" =~ ^ssh-ed25519\  ]] || { echo "not an ed25519 public key: ${key}" >&2; exit 1; }
  # ssh -R without a bind address asks to listen on "localhost", so that is
  # the host permitlisten has to name. `restrict` turns shell, pty, agent, X11
  # and all forwarding off; `port-forwarding` turns forwarding back on, and
  # `permitopen` then confines local (operator-side) forwarding to a port
  # nothing listens on, so the key can only ever open its own reverse port.
  # Without a permitopen the key could also reach whatever the bastion can.
  # There is no keyword that allows remote forwarding only. `false` via the
  # shell: NixOS has no /bin/false.
  echo "restrict,port-forwarding,permitopen=\"localhost:1\",permitlisten=\"localhost:${SUPPORT_PORT}\",command=\"false\" ${key}" \
    >> "${DIR}/authorized_keys"
}

create() {
  mkdir -p "${DIR}"
  chmod 700 "${DIR}"
  ssh-keygen -q -t ed25519 -N '' -C gvpn-test-bastion -f "${DIR}/host_key"
  ssh-keygen -q -t ed25519 -N '' -C gvpn-test-enroll -f "${DIR}/enroll"
  : > "${DIR}/authorized_keys"
  allow "$(< "${DIR}/enroll.pub")"
  echo "[${GUEST_HOST_ADDR}]:${BASTION_PORT} $(cut -d' ' -f1,2 "${DIR}/host_key.pub")" > "${DIR}/known_hosts"
  cat > "${DIR}/sshd_config" <<EOF
Port ${BASTION_PORT}
ListenAddress ${LISTEN_ADDR}
HostKey ${DIR}/host_key
PidFile ${DIR}/sshd.pid
AuthorizedKeysFile ${DIR}/authorized_keys
AllowUsers ${USER}
PasswordAuthentication no
KbdInteractiveAuthentication no
StrictModes no
GatewayPorts no
# Drop a session whose device stopped answering (a forced VM stop), so the
# rebooted device can bind its port again; docs/bastion.md uses 30 s, this is
# shorter so a rehearsal recovers quickly.
ClientAliveInterval 10
ClientAliveCountMax 3
LogLevel VERBOSE
EOF
}

cmd_start() {
  [[ -f "${DIR}/sshd_config" ]] || create
  if [[ -f "${DIR}/sshd.pid" ]] && kill -0 "$(< "${DIR}/sshd.pid")" 2>/dev/null; then
    echo "bastion already running on ${LISTEN_ADDR}:${BASTION_PORT}"
    return 0
  fi
  # sshd re-executes itself and therefore needs an absolute path.
  "$(command -v sshd)" -f "${DIR}/sshd_config" -E "${DIR}/sshd.log"
  echo "bastion running on ${LISTEN_ADDR}:${BASTION_PORT} (guest: ${GUEST_HOST_ADDR}:${BASTION_PORT}); log ${DIR}/sshd.log"
}

cmd_env() {
  [[ -f "${DIR}/sshd_config" ]] || { echo "no bastion; run: ${0} start" >&2; exit 1; }
  echo "export GVPN_BASTION=ssh://${USER}@${GUEST_HOST_ADDR}:${BASTION_PORT}"
  echo "export GVPN_SUPPORT_PORT=${SUPPORT_PORT}"
  echo "export GVPN_ENROLL_KEY=${DIR}/enroll"
  echo "export GVPN_BASTION_KNOWN_HOSTS=${DIR}/known_hosts"
}

cmd_stop() {
  if [[ -f "${DIR}/sshd.pid" ]]; then
    # The device sessions outlive the listener and keep holding their reverse
    # ports, which the next rehearsal's device would find taken.
    pkill -P "$(< "${DIR}/sshd.pid")" 2>/dev/null || true
    kill "$(< "${DIR}/sshd.pid")" 2>/dev/null || true
    rm -f "${DIR}/sshd.pid"
  fi
}

case "${1:-}" in
  start) cmd_start ;;
  env) cmd_env ;;
  allow) [[ -f "${DIR}/authorized_keys" ]] || { echo "no bastion; run: ${0} start" >&2; exit 1; }; allow "${2:?usage: bastion.sh allow KEY}" ;;
  stop) cmd_stop ;;
  *) echo "usage: ${0} start | env | allow KEY | stop" >&2; exit 64 ;;
esac
