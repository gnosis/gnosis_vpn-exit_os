#!/usr/bin/env bash
# Integration tests against the QEMU VM (`just vm-run` in another terminal).
# The VM is installed from an ISO built against the test bastion:
#   tests/integration/bastion.sh start; eval "$(tests/integration/bastion.sh env)"
#   just iso vm-install
#
#   tests/integration/run.sh unprovisioned   untouched image: the gate holds;
#                                            enrollment files only with
#                                            GVPN_BASTION (a LAN-only ISO
#                                            has none)
#   tests/integration/run.sh enroll          first access through the bastion
#   tests/integration/run.sh provision       provision with test values, reboot
#   tests/integration/run.sh provisioned     node services up, isolation in place
#   tests/integration/run.sh address         operator refresh and runtime address
#   tests/integration/run.sh update          stage a newer signed image, survive an
#                                            unprepared reboot, then apply it and
#                                            re-check the rollback trigger with a
#                                            second published digest
#                                            (publish one first: just build publish)
#
# Real OS, real systemd, SELinux enforcing, swtpm TPM2; no mocks.
set -euo pipefail

SSH_PORT="${VM_SSH_PORT:-2222}"
# An Incus VM is reached at its bridge address instead of QEMU's localhost
# forward. The bastion's reverse ports stay on the workstation's loopback.
SSH_HOST="${VM_SSH_HOST:-127.0.0.1}"
BASTION_HOST="${VM_BASTION_SSH_HOST:-127.0.0.1}"
# The device's reverse port, which the test bastion binds on the host's loopback.
SUPPORT_PORT="${GVPN_SUPPORT_PORT:-22001}"
BASTION="$(dirname "${BASH_SOURCE[0]}")/bastion.sh"
PUBLISH="$(dirname "${BASH_SOURCE[0]}")/../../tools/publish.sh"
SSH_KEY_ARGS=()
[[ -n "${VM_SSH_KEY:-}" ]] && SSH_KEY_ARGS=(-i "${VM_SSH_KEY}")
FAILURES=0

# ssh_devops HOST PORT COMMAND...: devops on the VM through HOST:PORT.
ssh_devops() {
  local host="$1" port="$2"
  shift 2
  ssh -q -p "${port}" "${SSH_KEY_ARGS[@]}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o BatchMode=yes devops@"${host}" "$@"
}

# Through QEMU's hostfwd, or the Incus bridge address, the LAN path.
vm() {
  ssh_devops "${SSH_HOST}" "${SSH_PORT}" "$@"
}

# The device answers through its reverse tunnel on the bastion. After a boot
# the support tunnel usually waits for support-tunnel-expire.timer (2 min
# after boot) because NTP syncs after its own start; autossh then retries
# every 60 s. The answer must come from this device: another device, such as
# one from an earlier rehearsal, may still hold the port on the bastion.
# A connection to the forwarded port is activity on the bastion's session, and
# sshd checks whether the client is alive only once the session has been idle
# for its ClientAliveInterval (10 s on the test bastion). Probing more often
# would keep a dead device's session, and the port, alive.
reachable_through_bastion() {
  local deadline=$((SECONDS + ${VM_BASTION_WAIT:-300})) expected
  expected="$(vm cat /etc/machine-id)" || return 1
  until [[ "$(ssh_devops "${BASTION_HOST}" "${SUPPORT_PORT}" cat /etc/machine-id 2>/dev/null)" == "${expected}" ]]; do
    (( SECONDS < deadline )) || return 1
    sleep 15
  done
}

# Run a bash script as root on the VM. ssh joins its arguments into one
# command line for the remote shell, so the script is quoted as one word.
vm_root_bash() {
  vm "sudo bash -c $(printf '%q' "$1")"
}

# vm_with_exit_override LINE COMMAND
# Run COMMAND as root on the VM with LINE appended to /etc/gvpn-exit/exit.env,
# then put that file back, also when COMMAND fails. cp -p carries its owner and
# mode, so the device keeps the file as it was. An exported value does not
# steer the device: load_exit_env sources the image defaults over the
# environment, so only the device's own exit.env overrides them.
vm_with_exit_override() {
  local line="$1" cmd="$2"
  vm_root_bash "set -euo pipefail
file=/etc/gvpn-exit/exit.env
saved=\"\$(mktemp)\"
existed=0
if [[ -e \"\${file}\" ]]; then
  cp -p \"\${file}\" \"\${saved}\"
  existed=1
fi
restore() {
  if (( existed )); then
    cp -p \"\${saved}\" \"\${file}\"
  else
    rm -f \"\${file}\"
  fi
  rm -f \"\${saved}\"
}
trap restore EXIT
# A leading newline, so a file without a trailing one keeps its last line.
printf '\n%s\n' $(printf '%q' "${line}") >> \"\${file}\"
${cmd}"
}

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name}"
    FAILURES=$((FAILURES + 1))
  fi
}

boot_id() {
  vm cat /proc/sys/kernel/random/boot_id
}

# Wait until the VM is back from a reboot that started after boot BEFORE.
wait_for_reboot() {
  local before="$1" now deadline=$((SECONDS + 900))
  while :; do
    now="$(boot_id 2>/dev/null || true)"
    [[ -n "${now}" && "${now}" != "${before}" ]] && break
    (( SECONDS < deadline )) || { echo "VM did not come back from the reboot"; exit 1; }
    sleep 5
  done
  wait_for_vm
}

# bootc status field (jq path), e.g. .status.booted.image.imageDigest
bootc_field() {
  vm sudo bootc status --format=json | jq -r "$1"
}

# bootc must refuse an unsigned image from the tracked repository: the
# signature policy has to apply to OS updates, not only to skopeo.
unsigned_refused() {
  local tracked="$1" probe="${1%:*}:unsigned-probe" output
  if output="$(vm sudo bootc switch --quiet "${probe}" 2>&1)"; then
    echo "bootc accepted the unsigned ${probe}; switching back to ${tracked}"
    vm sudo bootc switch --quiet "${tracked}" || true
    return 1
  fi
  grep -qi 'signature' <<< "${output}" || { echo "${output}"; return 1; }
}

wait_for_vm() {
  local deadline=$((SECONDS + 600))
  until vm true 2>/dev/null; do
    (( SECONDS < deadline )) || { echo "VM not reachable over SSH"; exit 1; }
    sleep 5
  done
  vm 'systemctl is-system-running --wait >/dev/null' || true
}

GATED_UNITS=(hoprd.service gnosisvpn-server.service gvpn-exit-data-guard.service
  gvpn-exit-hoprd-address.service gvpn-exit-capacity.service
  gvpn-exit-netprobe.timer hoprd-health.timer hoprd-preventive-restart.timer
  gvpn-exit-update-stage.timer gvpn-exit-update-apply.timer
  gvpn-exit-update-apply-now.service support-tunnel.service
  gvpn-blocklist-refresh.timer)

unit_condition_failed() {
  [[ "$(vm systemctl show -p ActiveState -p ConditionResult --value "$1" | tr '\n' ' ')" == "inactive no " ]]
}

unit_active() {
  vm systemctl is-active --quiet "$1"
}

# Socket listings on the device. The output is captured first, so a failed SSH
# connection fails the check instead of looking like "nothing is listening".
device_sockets() {
  vm sudo ss -lntupH
}

listener() {
  local sockets
  sockets="$(device_sockets)" || return 1
  awk '{print $5}' <<< "${sockets}" | grep -qE ":$1\$"
}

no_listener() {
  local sockets
  sockets="$(device_sockets)" || return 1
  ! awk '{print $5}' <<< "${sockets}" | grep -qE ":$1\$"
}

loopback_only_listener() {
  local sockets addrs
  sockets="$(vm sudo ss -lntH)" || return 1
  addrs="$(awk '{print $4}' <<< "${sockets}" | grep -E ":$1\$" || true)"
  [[ -n "${addrs}" ]] && ! grep -qvE "^127\.0\.0\.1:$1\$" <<< "${addrs}"
}

# The port is listened on only by local addresses: 127.0.0.1 plus any given
# alias addresses (the session target lives on lo).
local_only_listener() {
  local port="$1"
  local addr addrs sockets allowed="^127\.0\.0\.1:${port}$"
  shift
  sockets="$(vm sudo ss -lntH)" || return 1
  addrs="$(awk '{print $4}' <<< "${sockets}" | grep -E ":${port}\$" || true)"
  [[ -n "${addrs}" ]] || return 1
  for addr in "$@"; do
    allowed+="|^${addr//./\.}:${port}$"
  done
  ! grep -qvE "${allowed}" <<< "${addrs}"
}

# sshd listens on exactly the lan0 address and loopback: the dispatcher's
# drop-in took effect, which also proves sshd may read it under SELinux.
sshd_on_lan0_and_loopback() {
  local address sockets
  address="$(vm ip -4 -o addr show dev lan0 | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [[ -n "${address}" ]] || return 1
  sockets="$(vm sudo ss -lntH)" || return 1
  [[ "$(awk '$4 ~ /:22$/ {print $4}' <<< "${sockets}" | sort)" \
    == "$(printf '%s\n' "127.0.0.1:22" "${address}:22" | sort)" ]]
}

# The client's built-in session target address is assigned to lo.
session_target_on_lo() {
  vm sudo ip -4 -o addr show dev lo | grep -q '172\.30\.0\.1/32'
}

# Nothing listens on the port except on loopback (the port may be closed).
not_exposed() {
  local sockets
  sockets="$(vm sudo ss -lntuH)" || return 1
  ! awk '{print $5}' <<< "${sockets}" | grep -E ":$1\$" | grep -qvE "^127\.0\.0\.1:$1\$"
}

device_check() {
  vm_root_bash "source /usr/libexec/gvpn-exit/checks.sh; $1"
}

no_interface() {
  local links
  links="$(vm ip -o link show)" || return 1
  ! awk -F': ' '{print $2}' <<< "${links}" | grep -qx "$1"
}

htb_root() {
  vm sudo tc qdisc show dev "$1" root | grep -q htb
}

# The live WireGuard private key exists only on the /run tmpfs, never at rest.
wg_key_not_at_rest() {
  # shellcheck disable=SC2016 # expanded on the device
  vm_root_bash 'key="$(wg show wggvpn private-key)"; [[ -n "${key}" ]] && ! grep -rqsF "${key}" /etc /var'
}

# No SELinux denials this boot, except bootc's own capability probe: when
# bootc runs from a service (greenboot, data-guard, updates) it tests whether
# it may relabel to install_t with `chcon`, which unconfined_service_t may not
# (mac_admin). That probe is expected and reported separately.
BOOTC_PROBE_DENIAL='comm="chcon" capability=33 .*scontext=system_u:system_r:unconfined_service_t'

no_avc_denials() {
  local denials unexpected
  denials="$(vm_root_bash "journalctl -b -k --no-pager -q -g 'avc: +denied' || true")"
  unexpected="$(grep -vE "${BOOTC_PROBE_DENIAL}" <<< "${denials}" || true)"
  if [[ -n "${denials}" && "${denials}" != "${unexpected}" ]]; then
    echo "     (bootc install_t probe denied, expected)"
  fi
  [[ -z "${unexpected}" ]] || { echo "${unexpected}"; return 1; }
}

# gvpn-exit-status exits 0 (no FAIL) and its output matches the pattern.
# The output is captured first: `grep -q` in a pipe exits at the first match
# and the early close fails ssh (255) under pipefail.
status_reports() {
  local output
  output="$(vm sudo gvpn-exit-status)" || { echo "${output}"; return 1; }
  grep -qE "$1" <<< "${output}" || { echo "${output}"; return 1; }
}

# RPS mask of the first receive queue is not all zeros.
rps_enabled() {
  vm cat "/sys/class/net/$1/queues/rx-0/rps_cpus" | grep -q '[1-9a-f]'
}

common_checks() {
  check "uplink renamed to lan0" vm ip -br link show lan0 '>/dev/null'
  check "lan0 steers received packets to other CPUs" rps_enabled lan0
  local setting
  for setting in rmem_default rmem_max wmem_default wmem_max; do
    check "net.core.${setting} is 4 MiB" [ "$(vm sysctl -n "net.core.${setting}")" = "4194304" ]
  done
  # A socket opened without setsockopt must inherit both defaults.
  # shellcheck disable=SC2016 # expanded on the device
  check "new UDP sockets inherit 4 MiB receive and send buffers" vm_root_bash '
    exec 3<>/dev/udp/127.0.0.1/9
    while IFS= read -r line; do
      if [[ "${line}" == *"pid=$$,"* ]]; then
        IFS= read -r memory
        [[ "${memory}" == *",rb4194304,"* && "${memory}" == *",tb4194304,"* ]] && exit 0
      fi
    done < <(ss -u -a -n -m -p)
    exit 1
  '
  # `command -v` with several names succeeds when any one of them is found.
  # shellcheck disable=SC2016 # expanded on the device
  check "operator diagnostics installed" \
    vm 'for tool in ethtool top htop atop; do command -v "${tool}" >/dev/null || exit 1; done'
  check "sshd listens on the lan0 address and loopback only" sshd_on_lan0_and_loopback
  check "session target alias on lo" session_target_on_lo
  check "firewall loaded" unit_active gvpn-exit-firewall.service
  check "FORWARD isolation" device_check 'iptables -S FORWARD | forward_isolation_ok'
  # The verification-ping allowance ahead of the client drop is recognized from
  # WIREGUARD_CIDR and WIREGUARD_ADDRESS, as gvpn-exit-status and greenboot do.
  check "INPUT isolation" device_check 'load_exit_env; iptables -S INPUT | input_isolation_ok'
  check "IPv6 locked down" device_check 'ip6tables -S | ip6_policies_drop'
  check "host IPv6 disabled" [ "$(vm cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]
  check "node_exporter on loopback only" loopback_only_listener 9100
  check "netdata on loopback only" loopback_only_listener 19999
  check "blocklist cache seeded" vm sudo test -s /var/lib/gvpn-blocklist/blocklist.cidr
  # shellcheck disable=SC2016 # expanded on the device
  check "blocklist ipset populated" device_check '(( $(ipset list gvpn-blocklist | awk "/Number of entries/ {print \$4}") >= 1000 ))'
  check "SELinux enforcing" [ "$(vm getenforce)" = "Enforcing" ]
  check "no AVC denials this boot" no_avc_denials
  check "greenboot declared the boot healthy" unit_active boot-complete.target
  check "stock bootc auto-update masked" [ "$(vm systemctl is-enabled bootc-fetch-apply-updates.timer)" = "masked" ]
  check "sshd shows the MOTD" vm grep -q pam_motd.so /etc/pam.d/sshd
  check "MOTD points at gvpn-exit-status" vm grep -q gvpn-exit-status /usr/lib/motd.d/50-gvpn-exit
}

cmd_unprovisioned() {
  wait_for_vm
  local unit
  # Manual-only units need a start request before ConditionResult is evaluated.
  check "operator apply-now request is skipped before provisioning" \
    vm sudo systemctl start gvpn-exit-update-apply-now.service
  for unit in "${GATED_UNITS[@]}"; do
    check "${unit} inactive by condition" unit_condition_failed "${unit}"
  done
  for port in 9091 8000 51820 3001; do
    check "nothing listens on ${port}" no_listener "${port}"
  done
  check "no wggvpn interface" no_interface wggvpn
  # The bastion inputs that built the ISO say which device this is: with them
  # the installer wrote the first-access tunnel, without them (LAN-only, like
  # the published Incus ISO) it wrote none and enroll-tunnel stays off.
  if [[ -n "${GVPN_BASTION:-}" ]]; then
    check "installer wrote the enrollment key, root-only" [ "$(vm sudo stat -c %a:%U /etc/gvpn-exit/enroll.key)" = "600:root" ]
    check "installer wrote the bastion and port" vm grep -qx "SUPPORT_PORT=${SUPPORT_PORT}" /etc/gvpn-exit/support.env
    check "installer pinned the bastion host key" vm test -s /etc/gvpn-exit/bastion_known_hosts
    check "enroll-tunnel.service running" unit_active enroll-tunnel.service
  else
    check "installer wrote no bastion files" vm sudo test ! -e /etc/gvpn-exit/enroll.key \
      -a ! -e /etc/gvpn-exit/support.env -a ! -e /etc/gvpn-exit/bastion_known_hosts
    check "enroll-tunnel.service inactive by condition" unit_condition_failed enroll-tunnel.service
  fi
  check "gvpn-exit-status reports unprovisioned" status_reports 'state: +unprovisioned'
  common_checks
}

# Needs the test bastion running (tests/integration/bastion.sh start).
cmd_enroll() {
  wait_for_vm
  check "enroll-tunnel.service running" unit_active enroll-tunnel.service
  check "devops reachable through the bastion" reachable_through_bastion
}

cmd_provision() {
  : "${VM_BLOKLI_URL:?Set VM_BLOKLI_URL to the test network Blokli endpoint}"
  wait_for_vm
  vm sudo gvpn-exit-provision identity
  "${BASTION}" allow "$(vm sudo jq -r .support_public_key /var/lib/gvpn-exit/identity/node.json)"
  vm_root_bash "$(printf 'gvpn-exit-provision finalize --safe-address %q --module-address %q --blokli-url %q --location %q' \
    0x0000000000000000000000000000000000000001 \
    0x0000000000000000000000000000000000000002 \
    "${VM_BLOKLI_URL}" 'QEMU, XX')"
  vm sudo systemctl reboot || true
  sleep 10
  wait_for_vm
}

cmd_provisioned() {
  wait_for_vm
  local unit
  for unit in gvpn-exit-data-guard.service gnosisvpn-server.service hoprd.service \
      gvpn-exit-hoprd-address.service gvpn-exit-capacity.service \
      gvpn-exit-netprobe.timer hoprd-health.timer gvpn-exit-update-stage.timer; do
    check "${unit} active" unit_active "${unit}"
  done
  check "WireGuard key not stored in plaintext" wg_key_not_at_rest
  check "wggvpn up on 51820" [ "$(vm sudo wg show wggvpn listen-port)" = "51820" ]
  check "gnosis_vpn-server answers on the session target" vm curl -fsS -o /dev/null http://172.30.0.1:8000/api/v1/ping
  check "gnosis_vpn-server listens on local addresses only" local_only_listener 8000 172.30.0.1
  # hoprd opens its API only once the node is funded
  check "hoprd API never exposed beyond loopback" not_exposed 3001
  check "hoprd p2p listening on 9091" listener 9091
  check "WireGuard config rendered 0600 on tmpfs" [ "$(vm sudo stat -c %a /run/gnosisvpn-server/wggvpn.conf)" = "600" ]
  check "shaping on wggvpn" htb_root wggvpn
  check "shaping on ifb-gvpn" htb_root ifb-gvpn
  # The measurement cache, the derived pool and the rendered server range must
  # agree: a capacity sample that never reached the server would be invisible.
  # shellcheck disable=SC2016 # expanded on the device
  check "capacity probe recorded an outcome" device_check \
    'grep -Eq "^GVPN_CAPACITY_ATTEMPT=(ok|failed|skipped)$" "$(capacity_file)"'
  # shellcheck disable=SC2016 # expanded on the device
  check "server pool matches the derived capacity" device_check \
    'load_exit_env; grep -q "end = \"${GVPN_PEER_SUBNET_PREFIX}.${GVPN_PEER_MAX_OCTET}\"" /run/gnosisvpn-server/config.toml'
  # shellcheck disable=SC2016 # expanded on the device
  check "shaping has one class per peer slot" device_check \
    'load_exit_env; slots=$(( GVPN_PEER_MAX_OCTET - GVPN_PEER_MIN_OCTET + 1 )); [[ $(tc class show dev wggvpn | grep -c " parent 1:1 ") -eq ${slots} ]]'
  check "hoprd has a discovered announcement address" hoprd_address_loaded
  check "netprobe completes without failing on a known public address" \
    vm sudo systemctl start gvpn-exit-netprobe.service
  check "netprobe writes a network report" vm sudo jq -e \
    "'.nat as \$nat | ([\"ok\", \"cgnat\", \"double_nat\", \"unknown\"] | index(\$nat) != null) and (.cgnat == (\$nat == \"cgnat\")) and has(\"checked_at\")'" \
    /var/lib/gvpn-exit/state/reachability.json '>/dev/null'
  check "no inbound accept for the hoprd p2p port" device_check '! iptables -S INPUT | grep -q -- "--dport 9091"'
  # The static jump and the one wg-hooks.sh adds; the hooks must never remove the static one.
  # shellcheck disable=SC2016 # expanded on the device
  check "both GVPN_PRIVATE jumps in FORWARD" device_check '(( $(iptables -S FORWARD | grep -c -- "-i wggvpn .*-j GVPN_PRIVATE$") == 2 ))'
  # The clamp value follows the tunnel MTU; the exit drops oversized segments
  # when a peer announces more than the tunnel carries.
  # shellcheck disable=SC2016 # expanded on the device
  check "TCP MSS clamped in both directions" device_check \
    'load_exit_env; (( $(iptables -t mangle -S FORWARD | grep -c -- "--set-mss $(( WIREGUARD_MTU - 40 ))$") == 2 ))'
  check "enrollment key removed" vm sudo test ! -e /etc/gvpn-exit/enroll.key
  check "enroll-tunnel.service inactive by condition" unit_condition_failed enroll-tunnel.service
  # The tunnel starts with support-tunnel-expire.timer about 2 min after boot,
  # so wait for it to answer before asking whether the unit runs.
  check "devops reachable through the bastion" reachable_through_bastion
  check "support-tunnel.service running with the sealed key" unit_active support-tunnel.service
  check "gvpn-exit-status reports provisioned" status_reports 'state: +provisioned at'
  common_checks
}

# Compare only the address settings; never print the process's secret env vars.
# `systemctl restart` returns once the main process is forked; until systemd
# has loaded its credentials and exec'd it, its environment is the executor's,
# so give a fresh restart a moment.
hoprd_address_loaded() {
  # shellcheck disable=SC2016 # expanded on the device
  vm_root_bash 'set -euo pipefail
    file=/var/lib/gvpn-exit/state/hoprd-host.env
    [[ -s "${file}" ]] || exit 1
    for _ in $(seq 1 30); do
      pid="$(systemctl show -p MainPID --value hoprd.service)"
      if [[ "${pid}" != 0 ]] && actual="$(while IFS= read -r -d "" entry; do
          case "${entry}" in
            HOPRD_HOST=*|HOPRD_ANNOUNCE=*) printf "%s\n" "${entry}" ;;
          esac
        done < "/proc/${pid}/environ" | sort)" \
        && [[ "${actual}" == "$(sort "${file}")" && "${actual}" == *"HOPRD_ANNOUNCE=1"* ]]; then
        exit 0
      fi
      sleep 1
    done
    exit 1'
}

# End-to-end operator workflow on the installed OS. Does not prove that the
# funded node's on-chain announcement succeeded or that NAT ingress works.
cmd_address() {
  wait_for_vm
  check "operator refresh succeeds" vm sudo gvpn-exit-hoprd-address refresh
  check "Cloudflare-only operator refresh succeeds" vm_with_exit_override \
    'GVPN_PUBLIC_IP_URLS=https://www.cloudflare.com/cdn-cgi/trace' \
    'gvpn-exit-hoprd-address refresh'
  check "hoprd loads the saved announcement settings" hoprd_address_loaded
  local saved before
  saved="$(vm sudo cat /var/lib/gvpn-exit/state/hoprd-host.env)"
  before="$(vm systemctl show -p MainPID --value hoprd.service)"
  check "initialization with a saved address needs no echo service" \
    vm_with_exit_override 'GVPN_PUBLIC_IP_URLS=http://127.0.0.1:9' \
    'gvpn-exit-hoprd-address init'
  check "failed refresh reports failure" vm_with_exit_override \
    'GVPN_PUBLIC_IP_URLS=http://127.0.0.1:9' '! gvpn-exit-hoprd-address refresh'
  check "failed refresh preserves the address" \
    [ "$(vm sudo cat /var/lib/gvpn-exit/state/hoprd-host.env)" = "${saved}" ]
  check "failed refresh leaves hoprd running without a restart" \
    [ "$(vm systemctl show -p MainPID --value hoprd.service)" = "${before}" ]
  check "hoprd still uses the saved announcement settings" hoprd_address_loaded
}

# Needs a provisioned VM and a newer signed image on its channel (just build
# publish). Puts an unsigned probe next to it in the registry.
cmd_update() {
  local tracked before channel_digest boot unit address
  wait_for_vm
  address="$(vm sudo cat /var/lib/gvpn-exit/state/hoprd-host.env)"
  tracked="$(bootc_field '.spec.image.image')"
  before="$(bootc_field '.status.booted.image.imageDigest')"
  channel_digest="$(vm "sudo skopeo inspect --no-tags --format '{{.Digest}}' docker://${tracked}")"
  if [[ "${channel_digest}" == "${before}" ]]; then
    echo "the VM already runs ${tracked} (${before}); publish a newer image first: just build publish"
    exit 1
  fi
  echo "booted ${before}, ${tracked} is ${channel_digest}"

  # The probe is the device's own channel: it must be the image the device
  # would otherwise accept, with the signature stripped.
  "${PUBLISH}" unsigned-probe "${tracked##*:}"
  check "an unsigned image is refused by bootc" unsigned_refused "${tracked}"

  vm sudo systemctl start gvpn-exit-update-stage.service || true
  check "the signed update is staged" [ "$(bootc_field '.status.staged.image.imageDigest')" = "${channel_digest}" ]
  if [[ "$(bootc_field '.status.staged.image.imageDigest')" != "${channel_digest}" ]]; then
    echo "nothing to apply; see: journalctl -u gvpn-exit-update-stage.service"
    exit 1
  fi
  check "the staged update is download-only" [ "$(bootc_field '.status.staged.downloadOnly')" = "true" ]

  # A reboot update-apply.sh did not prepare (no snapshot, no data owner for
  # the update) must boot the current deployment again.
  boot="$(boot_id)"
  vm sudo systemctl reboot || true
  wait_for_reboot "${boot}"
  check "an unprepared reboot keeps the booted deployment" [ "$(bootc_field '.status.booted.image.imageDigest')" = "${before}" ]
  check "the data owner is unchanged" [ "$(vm sudo cat /var/lib/gvpn-exit/state/data-owner)" = "${before}" ]
  check "reboot preserves the announcement address" [ "$(vm sudo cat /var/lib/gvpn-exit/state/hoprd-host.env)" = "${address}" ]
  for unit in gvpn-exit-data-guard.service hoprd.service; do
    check "${unit} active after the unprepared reboot" unit_active "${unit}"
  done
  vm sudo systemctl start gvpn-exit-update-stage.service || true
  check "the update is staged again" [ "$(bootc_field '.status.staged.image.imageDigest')" = "${channel_digest}" ]

  boot="$(boot_id)"
  # The operator service bypasses the window, not the snapshot or ownership
  # preparation. The reboot ends the SSH session.
  vm sudo systemctl start gvpn-exit-update-apply-now.service || true
  wait_for_reboot "${boot}"

  check "booted the update" [ "$(bootc_field '.status.booted.image.imageDigest')" = "${channel_digest}" ]
  check "update preserves the announcement address" [ "$(vm sudo cat /var/lib/gvpn-exit/state/hoprd-host.env)" = "${address}" ]
  check "the previous deployment is the rollback" [ "$(bootc_field '.status.rollback.image.imageDigest')" = "${before}" ]
  check "the update owns the hoprd data" [ "$(vm sudo cat /var/lib/gvpn-exit/state/data-owner)" = "${channel_digest}" ]
  check "the previous owner is recorded" [ "$(vm sudo cat /var/lib/gvpn-exit/state/data-owner-previous)" = "${before}" ]
  check "hoprd DB snapshot of the previous deployment" vm sudo test -d "/var/lib/hoprd-v5.snapshots/${before}"
  for unit in gvpn-exit-data-guard.service gnosisvpn-server.service hoprd.service; do
    check "${unit} active" unit_active "${unit}"
  done
  check "devops reachable through the bastion" reachable_through_bastion
  check "gvpn-exit-status reports provisioned" status_reports 'state: +provisioned at'

  # Regression for download-only staging vs greenboot's rollback trigger: the
  # update above left a rollback deployment behind, which is the state the bug
  # needs. Stage a digest newer than the booted one and reboot without
  # preparation: greenboot must neither queue a rollback nor see a fallback.
  local second
  second="$(vm "sudo skopeo inspect --no-tags --format '{{.Digest}}' docker://${tracked}")"
  if [[ "${second}" == "${channel_digest}" ]]; then
    echo "SKIP the rollback-trigger regression: ${tracked} still points at ${channel_digest};"
    echo "     publish a newer image (just build publish) and rerun the update phase"
  else
    vm sudo systemctl start gvpn-exit-update-stage.service || true
    check "a second update is staged" [ "$(bootc_field '.status.staged.image.imageDigest')" = "${second}" ]
    boot="$(boot_id)"
    vm sudo systemctl reboot || true
    wait_for_reboot "${boot}"
    check "an unprepared reboot with a rollback deployment keeps the booted deployment" \
      [ "$(bootc_field '.status.booted.image.imageDigest')" = "${channel_digest}" ]
    check "no rollback is queued" [ "$(bootc_field '.status.rollbackQueued')" = "false" ]
    check "greenboot detects no kernel fallback" \
      vm_root_bash '! journalctl -b -u greenboot-healthcheck --no-pager | grep -q "fallback detected"'
  fi
  common_checks
}

case "${1:-}" in
  unprovisioned) cmd_unprovisioned ;;
  enroll) cmd_enroll ;;
  provision) cmd_provision ;;
  provisioned) cmd_provisioned ;;
  address) cmd_address ;;
  update) cmd_update ;;
  *) echo "usage: ${0} unprovisioned|enroll|provision|provisioned|address|update" >&2; exit 64 ;;
esac

echo
if (( FAILURES > 0 )); then
  echo "${FAILURES} check(s) failed"
  exit 1
fi
echo "all checks passed"
