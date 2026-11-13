#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../../../libexec/gvpn-exit/checks.sh
source "${GVPN_LIBEXEC_DIR:-/usr/libexec/gvpn-exit}/checks.sh"
load_exit_env
IPSET_BIN="${GVPN_IPSET_BIN:-ipset}"

# Required check: LAN/host isolation of VPN clients, the tunnel verification
# ping the client needs, and the IPv6 lockdown.
if ! is_provisioned; then
  echo "unprovisioned, skipping"
  exit 0
fi

# The tunnel-ping allowance is installed by wg-hooks.sh when wggvpn comes up,
# which can be a moment after gnosisvpn-server is active; wait for it instead
# of turning a slow start into a red boot.
READY_TIMEOUT_S="${GVPN_READY_TIMEOUT_S:-60}"

ping_rule_present() {
  iptables -S INPUT | input_vpn_ping_ok
}

iptables -S FORWARD | forward_isolation_ok \
  || { echo "FORWARD: GVPN_PRIVATE jump missing, or a rule ahead of it that can pass client traffic"; exit 1; }
iptables -S INPUT | input_isolation_ok \
  || { echo "INPUT: wggvpn DROP missing, or a rule ahead of it that can pass client traffic"; exit 1; }
wait_for "${READY_TIMEOUT_S}" ping_rule_present \
  || { echo "INPUT: tunnel verification ping to the WireGuard address missing or behind the wggvpn DROP"; exit 1; }
iptables -S GVPN_PRIVATE | self_ipset_rule_ok || { echo "GVPN_PRIVATE: self-address DROP missing"; exit 1; }
"${IPSET_BIN}" list "${GVPN_SELF_IPSET_NAME}" > /dev/null || { echo "self-address ipset ${GVPN_SELF_IPSET_NAME} missing"; exit 1; }
ip6tables -S | ip6_policies_drop || { echo "ip6tables policies are not all DROP"; exit 1; }
echo "firewall isolation in place"
