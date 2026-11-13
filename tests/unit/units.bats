#!/usr/bin/env bats
# Static checks on the shipped systemd units: the provisioning gate sits on
# every unit that must not run unprovisioned (a condition does not propagate
# through Requires=), and everything that listens or forwards requires the
# firewall.

load helpers

UNITS="${BATS_TEST_DIRNAME}/../../image/rootfs/usr/lib/systemd/system"
GATE='ConditionPathExists=/var/lib/gvpn-exit/identity/provisioned'

# All unit text for NAME: the unit file plus its drop-ins.
unit_text() {
  local dropin
  cat "${UNITS}/$1"
  for dropin in "${UNITS}/$1.d/"*.conf; do
    [[ -f "${dropin}" ]] && cat "${dropin}"
  done
  return 0
}

@test "every unit that must not run unprovisioned carries the gate itself" {
  for unit in hoprd.service gnosisvpn-server.service gvpn-exit-data-guard.service \
      gvpn-exit-hoprd-address.service \
      hoprd-health.service hoprd-health.timer \
      hoprd-preventive-restart.service hoprd-preventive-restart.timer \
      gvpn-exit-netprobe.service gvpn-exit-netprobe.timer \
      gvpn-exit-capacity.service \
      gvpn-exit-heartbeat.service gvpn-exit-heartbeat.timer \
      gvpn-exit-update-stage.service gvpn-exit-update-stage.timer \
      gvpn-exit-update-apply.service gvpn-exit-update-apply.timer \
      gvpn-exit-update-apply-now.service \
      support-tunnel.service support-tunnel-expire.service support-tunnel-expire.timer \
      gvpn-blocklist-refresh.service gvpn-blocklist-refresh.timer; do
    unit_text "${unit}" | grep -qx "${GATE}" || { echo "${unit} is not gated"; false; }
  done
}

@test "the enrollment tunnel runs only while the device is unprovisioned" {
  grep -qx 'ConditionPathExists=!/var/lib/gvpn-exit/identity/provisioned' "${UNITS}/enroll-tunnel.service"
  grep -qx 'ConditionPathExists=/etc/gvpn-exit/support.env' "${UNITS}/enroll-tunnel.service"
  grep -qx 'ConditionPathExists=/etc/gvpn-exit/enroll.key' "${UNITS}/enroll-tunnel.service"
}

@test "both tunnels share one autossh command, each with its own key" {
  grep -qx 'ExecStart=/usr/libexec/gvpn-exit/support-tunnel.sh %d/enroll.key' "${UNITS}/enroll-tunnel.service"
  grep -qx 'ExecStart=/usr/libexec/gvpn-exit/support-tunnel.sh %d/support.key' "${UNITS}/support-tunnel.service"
  run grep -l 'autossh' "${UNITS}"/*.service
  [ "${status}" -eq 1 ]
}

@test "hoprd waits for best-effort address initialization but not periodic netprobe" {
  local text address line
  text="$(unit_text hoprd.service)"
  [[ "${text}" == *"Wants=network-online.target gvpn-exit-hoprd-address.service"* ]]
  [[ "${text}" == *"After="*"gvpn-exit-hoprd-address.service"* ]]
  [[ "${text}" == *"EnvironmentFile=-/var/lib/gvpn-exit/state/hoprd-host.env"* ]]
  [[ "${text}" != *netprobe* ]]
  while IFS= read -r line; do
    [[ "${line}" != Requires=*gvpn-exit-hoprd-address.service* ]]
  done <<< "${text}"
  address="$(unit_text gvpn-exit-hoprd-address.service)"
  [[ "${address}" == *"RemainAfterExit=yes"* ]]
  [[ "${address}" == *"ExecStart=/usr/bin/gvpn-exit-hoprd-address init"* ]]
  [[ "${address}" != *"Restart="* ]]
  [ ! -e "${UNITS}/gvpn-exit-hoprd-address.timer" ]
}

@test "the firewall, loopback alias and cache-only blocklist load run unprovisioned" {
  for unit in gvpn-exit-firewall.service gvpn-exit-loopback-alias.service gvpn-blocklist-boot.service; do
    [ -f "${UNITS}/${unit}" ]
    ! unit_text "${unit}" | grep -q 'identity/provisioned'
  done
}

@test "gnosis_vpn-server waits for the session target alias" {
  local text
  text="$(unit_text gnosisvpn-server.service)"
  grep -q '^Requires=.*gvpn-exit-loopback-alias.service' <<< "${text}"
  grep -q '^After=.*gvpn-exit-loopback-alias.service' <<< "${text}"
}

@test "everything that listens or forwards requires the firewall" {
  for unit in hoprd.service gnosisvpn-server.service sshd.service node_exporter.service netdata.service support-tunnel.service enroll-tunnel.service; do
    text="$(unit_text "${unit}")"
    grep -q '^Requires=.*gvpn-exit-firewall.service' <<< "${text}" || { echo "${unit} lacks Requires="; false; }
    grep -q '^After=.*gvpn-exit-firewall.service' <<< "${text}" || { echo "${unit} lacks After="; false; }
  done
}

@test "hoprd cannot start without the data guard" {
  unit_text hoprd.service | grep -q '^Requires=.*gvpn-exit-data-guard.service'
  unit_text hoprd.service | grep -q '^After=.*gvpn-exit-data-guard.service'
}

# hoprd's session allow-list names the address on lo; without the alias a
# session to it takes the default route instead.
@test "hoprd cannot start without the session target alias" {
  unit_text hoprd.service | grep -q '^Requires=.*gvpn-exit-loopback-alias.service'
  unit_text hoprd.service | grep -q '^After=.*gvpn-exit-loopback-alias.service'
}

# An ExecStop `kill` would run as the hoprd user; a restart right after a
# start meets a main process that is still systemd's root-owned executor
# loading the credentials, and that kill fails with EPERM.
@test "systemd itself sends hoprd its graceful stop signal" {
  text="$(unit_text hoprd.service)"
  run grep '^ExecStop=' <<< "${text}"
  [ "${status}" -eq 1 ]
  [ "$(grep '^KillSignal=' <<< "${text}")" = "KillSignal=SIGINT" ]
  grep -qx 'KillMode=process' <<< "${text}"
  grep -qx 'TimeoutStopSec=90' <<< "${text}"
}

# The unit is written for the appliance: one file states every setting once,
# so nothing depends on the order in which a drop-in resets a list.
@test "hoprd.service is a single unit that runs the appliance wrapper as hoprd" {
  [ ! -e "${UNITS}/hoprd.service.d" ]
  [ "$(grep -c '^ExecStart=' "${UNITS}/hoprd.service")" -eq 1 ]
  grep -qx 'ExecStart=/usr/libexec/gvpn-exit/hoprd-run.sh' "${UNITS}/hoprd.service"
  grep -qx 'User=hoprd' "${UNITS}/hoprd.service"
  grep -qx 'Group=hoprd' "${UNITS}/hoprd.service"
  run grep -e '^EnvironmentFile=$' -e '/etc/hoprd/hoprd.env$' "${UNITS}/hoprd.service"
  [ "${status}" -eq 1 ]
  grep -qx 'WantedBy=multi-user.target' "${UNITS}/hoprd.service"
}

@test "hoprd is held stopped until the v5 provisioning file exists" {
  unit_text hoprd.service | grep -qx 'ConditionPathExists=/etc/hoprd-v5/hoprd.env.d/10-provisioned.env'
}

@test "hoprd reads only the v5 provisioning file, never the v4 one" {
  local text
  text="$(unit_text hoprd.service)"
  grep -qx 'EnvironmentFile=-/etc/hoprd-v5/hoprd.env.d/10-provisioned.env' <<< "${text}"
  ! grep -q '^EnvironmentFile=-/etc/hoprd/hoprd.env.d/' <<< "${text}"
}

@test "hoprd runs from the v5 state directory and a private runtime directory" {
  local text
  text="$(unit_text hoprd.service)"
  grep -qx 'StateDirectory=hoprd-v5' <<< "${text}"
  grep -qx 'RuntimeDirectory=hoprd' <<< "${text}"
  grep -qx 'RuntimeDirectoryMode=0700' <<< "${text}"
  grep -qx 'StateDirectoryMode=0700' <<< "${text}"
  # hoprd-run.sh sets this to the copy it makes in RuntimeDirectory.
  ! grep -q '^Environment=HOPRD_IDENTITY=' <<< "${text}"
}

@test "update staging never reboots and apply is window-checked by its script" {
  # --download-only: a reboot that update-apply.sh did not prepare keeps the
  # booted deployment instead of finalizing the staged one at shutdown.
  grep -qx 'ExecStart=/usr/bin/flock /run/gvpn-exit/update.lock /usr/bin/bootc upgrade --download-only --quiet' "${UNITS}/gvpn-exit-update-stage.service"
  grep -qx 'ExecCondition=/usr/libexec/gvpn-exit/update-allowed.sh' "${UNITS}/gvpn-exit-update-stage.service"
  grep -qx 'ExecStart=/usr/bin/flock /run/gvpn-exit/update.lock /usr/libexec/gvpn-exit/update-apply.sh' "${UNITS}/gvpn-exit-update-apply.service"
}

@test "operator apply-now uses the shared script and has no automatic activation" {
  local text
  text="$(unit_text gvpn-exit-update-apply-now.service)"
  [[ "${text}" == *"ConditionPathExists=/run/ostree-booted"* ]]
  [[ "${text}" == *"ExecStart=/usr/bin/flock /run/gvpn-exit/update.lock /usr/libexec/gvpn-exit/update-apply.sh --now"* ]]
  [[ "${text}" != *"[Install]"* ]]
  [ ! -e "${UNITS}/gvpn-exit-update-apply-now.timer" ]
}

@test "staging cannot replace the deployment update-apply is releasing" {
  # Both hold one lock, so apply's read, snapshot, release and ownership
  # record all see the same staged deployment.
  for unit in gvpn-exit-update-stage.service gvpn-exit-update-apply.service gvpn-exit-update-apply-now.service; do
    grep -q '^ExecStart=/usr/bin/flock /run/gvpn-exit/update.lock ' "${UNITS}/${unit}" || { echo "${unit} does not take the update lock"; false; }
  done
}

@test "every ExecStart script referenced by a unit ships in the image" {
  for path in $(grep -ho '/usr/libexec/gvpn-exit/[a-z-]*\.sh' "${UNITS}"/*.service "${UNITS}"/*.d/*.conf | sort -u); do
    [ -x "${ROOTFS}${path}" ] || { echo "${path} missing or not executable"; false; }
  done
}

@test "the rollback trigger is armed by the appliance wrapper, not by greenboot" {
  # greenboot-rs arms its trigger from any staged deployment; the wrapper keeps
  # a download-only update from turning an ordinary reboot into a rollback.
  local text
  text="$(unit_text greenboot-set-rollback-trigger.service)"
  grep -qx 'ExecStop=' <<< "${text}"
  grep -qx 'ExecStop=/usr/libexec/gvpn-exit/rollback-trigger.sh' <<< "${text}"
}

@test "services reachable from the outside run in a strict sandbox" {
  # gnosisvpn-server is on hoprd's session allow-list and hoprd is a p2p node:
  # both are reachable from outside the device.
  local unit text
  for unit in gnosisvpn-server.service hoprd.service; do
    text="$(unit_text "${unit}")"
    for directive in ProtectSystem=strict ProtectHome=yes PrivateTmp=yes NoNewPrivileges=yes SystemCallFilter=@system-service; do
      grep -qx "${directive}" <<< "${text}" || { echo "${unit} lacks ${directive}"; false; }
    done
  done
  # The server's hooks run iptables inside its namespace, which locks
  # /run/xtables.lock; /run is granted because a ReadWritePaths= file that does
  # not exist fails the unit.
  grep -qx 'ReadWritePaths=/run' <<< "$(unit_text gnosisvpn-server.service)"
}

@test "the support tunnels run as a dynamic user with their key as a credential" {
  local text
  for unit in support-tunnel.service enroll-tunnel.service; do
    text="$(unit_text "${unit}")"
    grep -qx 'DynamicUser=yes' <<< "${text}" || { echo "${unit} is not dynamic"; false; }
    grep -qx 'CapabilityBoundingSet=' <<< "${text}" || { echo "${unit} keeps capabilities"; false; }
    grep -qx 'ProtectSystem=strict' <<< "${text}" || { echo "${unit} is not sandboxed"; false; }
  done
  grep -qx 'LoadCredentialEncrypted=support.key:/var/lib/gvpn-exit/creds/support.key.cred' \
    <<< "$(unit_text support-tunnel.service)"
  grep -qx 'LoadCredential=enroll.key:/etc/gvpn-exit/enroll.key' <<< "$(unit_text enroll-tunnel.service)"
}

@test "the heartbeat signs with the sealed support key" {
  grep -qx 'LoadCredentialEncrypted=support.key:/var/lib/gvpn-exit/creds/support.key.cred' \
    "${UNITS}/gvpn-exit-heartbeat.service"
}

@test "the daily hoprd restart is spread over the last hour of the window" {
  # Every device restarting at the same minute takes the exits down together.
  local text
  text="$(unit_text hoprd-preventive-restart.timer)"
  grep -qx 'OnCalendar=\*-\*-\* 05:00:00' <<< "${text}"
  grep -qx 'RandomizedDelaySec=1h' <<< "${text}"
}

@test "the netprobe asks the public-IP services every 15 minutes" {
  local text
  text="$(unit_text gvpn-exit-netprobe.timer)"
  grep -qx 'OnUnitActiveSec=15min' <<< "${text}"
  grep -qx 'OnBootSec=1min' <<< "${text}"
}

# chronyd is an NTP client only; a listener would need the firewall dependency
# every listening unit carries.
@test "the time daemon serves no time" {
  grep -qx 'port 0' "${ROOTFS}/etc/chrony.conf"
}

@test "the capacity probe runs once before the server without gating it" {
  local capacity server
  capacity="$(unit_text gvpn-exit-capacity.service)"
  server="$(unit_text gnosisvpn-server.service)"
  grep -qx 'Before=gnosisvpn-server.service' <<< "${capacity}"
  grep -qx 'Type=oneshot' <<< "${capacity}"
  grep -qx 'RemainAfterExit=yes' <<< "${capacity}"
  grep -qx 'TimeoutStartSec=120' <<< "${capacity}"
  grep -qx 'ExecStart=/usr/libexec/gvpn-exit/capacity.sh' <<< "${capacity}"
  # A failed measurement must never keep the VPN down, so no Requires=.
  [[ "${server}" == *"Wants=network-online.target gvpn-blocklist-boot.service gvpn-exit-capacity.service"* ]]
  [[ "${server}" == *"After="*"gvpn-exit-capacity.service"* ]]
  while IFS= read -r line; do
    [[ "${line}" != Requires=*gvpn-exit-capacity.service* ]]
  done <<< "${server}"
}

@test "the capacity probe can write the sample and nothing else" {
  local text
  text="$(unit_text gvpn-exit-capacity.service)"
  grep -qx 'ReadWritePaths=/var/lib/gvpn-exit/state' <<< "${text}"
  grep -qx 'ProtectSystem=strict' <<< "${text}"
  grep -qx 'NoNewPrivileges=yes' <<< "${text}"
  # It measures the link with a third-party client; it never needs privilege.
  grep -qx 'CapabilityBoundingSet=' <<< "${text}"
  grep -qx 'RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX' <<< "${text}"
  grep -qx 'RestrictNamespaces=yes' <<< "${text}"
  grep -qx 'ProtectKernelTunables=yes' <<< "${text}"
}
