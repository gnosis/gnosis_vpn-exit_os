#!/usr/bin/env bash
# enroll-tunnel.service and support-tunnel.service: reverse SSH tunnel to the
# support bastion. Port SUPPORT_PORT on the bastion's loopback forwards to
# this device's sshd, so operators reach devops without any inbound port on
# the device's LAN. The units differ only in the key: the enrollment key
# from the installer while unprovisioned, the TPM-sealed support key inside a
# support window afterwards.
#
#   support-tunnel.sh KEY_FILE
#
# SUPPORT_PORT and BASTION come from /etc/gvpn-exit/support.env
# (EnvironmentFile=). The bastion host key is pinned in known_hosts form in
# GVPN_BASTION_KNOWN_HOSTS, written by the installer.
set -euo pipefail

GVPN_BASTION_KNOWN_HOSTS="${GVPN_BASTION_KNOWN_HOSTS:-/etc/gvpn-exit/bastion_known_hosts}"

main() {
  local key="${1:?usage: support-tunnel.sh KEY_FILE}"
  : "${SUPPORT_PORT:?SUPPORT_PORT missing (support.env)}"
  : "${BASTION:?BASTION missing (support.env)}"
  exec autossh -M 0 -N \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${GVPN_BASTION_KNOWN_HOSTS}" \
    -o IdentitiesOnly=yes -i "${key}" \
    -R "${SUPPORT_PORT}:127.0.0.1:22" "${BASTION}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
