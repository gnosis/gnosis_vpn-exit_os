#!/usr/bin/env bash
# Install and run the appliance ISO in an Incus VM instead of on hardware.
# The guest mirrors the supported x86 appliance properties: UEFI (Secure Boot
# off, as in the hardware setup), a vTPM for the sealed credentials, a
# virtio-scsi root disk (sda) and one virtio NIC (renamed lan0 by the image).
#
#   tools/incus.sh install [ISO]   fresh VM, boot the unattended installer
#   tools/incus.sh run             detach the ISO, boot the installed disk
#   tools/incus.sh ssh [ARGS...]   ssh as devops to the VM's bridge address
#   tools/incus.sh ip              print that address
#   tools/incus.sh console         attach to the serial console (leave: Ctrl-a q)
#   tools/incus.sh destroy         delete the VM, its disk and its vTPM
#
# Incus is a host tool (Linux only) and is not shipped by the devshell. Use
# `just incus-install` with the devshell on PATH, or `nix develop -c just ...`.
# GVPN_INCUS_VM names the instance (default gvpn-exit); GVPN_INCUS_CPUS,
# GVPN_INCUS_MEMORY and GVPN_INCUS_DISK_SIZE size it. The defaults are the
# recommended production size: 8 vCPUs, 16 GiB RAM and a 64 GiB disk.
set -euo pipefail

INVOCATION_DIR="$PWD"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAME="${GVPN_INCUS_VM:-gvpn-exit}"
CPUS="${GVPN_INCUS_CPUS:-8}"
MEMORY="${GVPN_INCUS_MEMORY:-16GiB}"
DISK_SIZE="${GVPN_INCUS_DISK_SIZE:-64GiB}"
DEFAULT_ISO="output/iso/bootiso/install.iso"

die() {
  echo "$*" >&2
  exit 1
}

require_incus() {
  command -v incus >/dev/null 2>&1 \
    || die "incus is not on PATH; install Incus on the Linux host (the devshell does not ship it)"
}

instance_exists() {
  incus info "${NAME}" >/dev/null 2>&1
}

require_instance() {
  instance_exists || die "no Incus VM '${NAME}'; create it with: just incus-install"
}

# `incus list NAME` is a prefix filter, so a helper selects the exact name to
# keep `gvpn-exit` apart from `gvpn-exit-2`.
instance_json() {
  incus list "${NAME}" --format=json \
    | jq --arg name "${NAME}" 'map(select(.name == $name))[0] // empty'
}

# The IPv4 address Incus learned from the bridge's DHCP server. The VM has no
# Incus agent, so `incus exec` is not available and SSH is the way in.
cmd_ip() {
  require_incus
  require_instance
  local ip
  ip="$(instance_json \
    | jq -r '.state.network // {} | to_entries[] | .value.addresses[]?
             | select(.family == "inet" and .scope == "global") | .address' \
    | awk 'NF { print; exit }')"
  [[ -n "${ip}" ]] || die "Incus VM '${NAME}' has no IPv4 address yet; check: incus list ${NAME}"
  printf '%s\n' "${ip}"
}

cmd_install() {
  local iso="${1:-}"
  if [[ -n "${iso}" && "${iso}" != /* ]]; then
    iso="${INVOCATION_DIR}/${iso}"
  else
    iso="${iso:-${DEFAULT_ISO}}"
  fi
  [[ -f "${iso}" ]] || die "no installer ISO at ${iso}; build one with: just iso"
  # incusd resolves a disk source in its own process, not in this shell: hand
  # it an absolute path even though the recipes use repository-relative ones.
  iso="$(realpath "${iso}")"
  require_incus
  instance_exists && die "Incus VM '${NAME}' already exists; delete it first with: just incus-destroy"

  # A target sidecar comes from the build. An ISO that detects its disk fits;
  # refuse one pinned to another disk (such as the hardware nvme0n1) instead
  # of letting the kickstart fail to find it.
  if [[ -f "${iso}.target" ]]; then
    local expected_disk="${GVPN_INCUS_INSTALL_DISK:-sda}" pinned
    if ! grep -qx -e 'disk=auto' -e "disk=${expected_disk}" "${iso}.target"; then
      pinned="$(sed -n 's/^disk=//p' "${iso}.target" | head -n1)"
      die "${iso} pins install disk ${pinned:-unknown}, not Incus disk ${expected_disk}; build it with: just iso (detects the disk) or GVPN_INSTALL_DISK=${expected_disk} just iso"
    fi
  fi

  # The root disk is virtio-scsi (sda); the installer detects it as the only
  # disk, or is pinned to it. The installed disk outranks the still-attached
  # ISO after the install, so an ejected-but-still-present CD cannot reinstall
  # on reboot.
  # Each -d takes exactly one device,key=value pair.
  incus init "${NAME}" --empty --vm \
    -c limits.cpu="${CPUS}" -c limits.memory="${MEMORY}" \
    -c security.secureboot=false \
    -d "root,size=${DISK_SIZE}" -d root,boot.priority=10
  # Provisioning seals credentials into a TPM2; a VM without one cannot
  # provision. The vTPM state lives with the instance and is deleted with it.
  incus config device add "${NAME}" tpm tpm
  # The empty root disk is not bootable yet; the ISO boots first.
  incus config device add "${NAME}" install disk source="${iso}" boot.priority=5

  echo "installing ${iso} into Incus VM '${NAME}'"
  echo "the installer reboots when done; leave the console with Ctrl-a q, then run: just incus-run"
  incus start "${NAME}" --console
}

instance_status() {
  instance_json | jq -r '.status // "Unknown"'
}

wait_for_ip() {
  local deadline=$((SECONDS + ${GVPN_INCUS_IP_WAIT:-60})) ip
  while :; do
    if ip="$(cmd_ip 2>/dev/null)"; then
      printf '%s\n' "${ip}"
      return 0
    fi
    (( SECONDS < deadline )) || return 1
    sleep 2
  done
}

cmd_run() {
  require_incus
  require_instance
  local status ip
  status="$(instance_status)"
  # Only the installer boot needs stopping and the install disk removing. On
  # an installed VM `incus-run` starts a stopped VM and leaves a running one
  # alone instead of killing it.
  if incus config device list "${NAME}" | grep -qx install; then
    if [[ "${status}" == "Running" ]]; then
      # The installer reboot may already have reached the installed system;
      # ask it to stop first, then force only if that does not finish.
      incus stop "${NAME}" --timeout=60 >/dev/null 2>&1 \
        || incus stop "${NAME}" --force >/dev/null 2>&1 || true
    fi
    incus config device remove "${NAME}" install >/dev/null
    status="$(instance_status)"
  fi
  if [[ "${status}" != "Running" ]]; then
    incus start "${NAME}"
  fi
  echo "booting Incus VM '${NAME}'"
  if ip="$(wait_for_ip)"; then
    echo "ssh: just incus-ssh   (devops@${ip})"
  else
    echo "no IPv4 address yet; check: incus list ${NAME}"
  fi
}

cmd_ssh() {
  require_incus
  require_instance
  local ip key_args=()
  ip="$(cmd_ip)"
  [[ -n "${VM_SSH_KEY:-}" ]] && key_args=(-i "${VM_SSH_KEY}")
  exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${key_args[@]}" "devops@${ip}" "$@"
}

cmd_console() {
  require_incus
  require_instance
  incus console "${NAME}"
}

cmd_destroy() {
  require_incus
  require_instance
  # --force also deletes a running instance.
  incus delete "${NAME}" --force
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  run) cmd_run ;;
  ssh) shift; cmd_ssh "$@" ;;
  ip) cmd_ip ;;
  console) cmd_console ;;
  destroy) cmd_destroy ;;
  *) echo "usage: ${0} install [ISO] | run | ssh [ARGS...] | ip | console | destroy" >&2; exit 64 ;;
esac
