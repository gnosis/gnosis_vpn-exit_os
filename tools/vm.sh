#!/usr/bin/env bash
# QEMU harness mirroring the supported x86 appliance properties: UEFI (OVMF),
# TPM2 (swtpm), NVMe disk, one virtio NIC (renamed lan0 by the image). State
# lives in output/vm.
#
#   tools/vm.sh install ISO   fresh disk, run the unattended installer, exit
#   tools/vm.sh run           boot the installed disk; SSH on localhost:2222
#   tools/vm.sh run-headless  same, serial console to output/vm/console.log
#
# Needs OVMF_CODE / OVMF_VARS (set by the nix devshell), qemu, swtpm.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
VM_DIR="output/vm"
DISK="${VM_DIR}/disk.qcow2"
VARS="${VM_DIR}/OVMF_VARS.fd"
TPM_DIR="${VM_DIR}/tpm"
SSH_PORT="${VM_SSH_PORT:-2222}"
: "${OVMF_CODE:?run inside nix develop}"
: "${OVMF_VARS:?run inside nix develop}"

SWTPM_PID=""
cleanup() {
  if [[ -n "${SWTPM_PID}" ]]; then
    kill "${SWTPM_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

start_swtpm() {
  mkdir -p "${TPM_DIR}"
  swtpm socket --tpm2 --tpmstate "dir=${TPM_DIR}" \
    --ctrl "type=unixio,path=${TPM_DIR}/sock" --flags startup-clear &
  SWTPM_PID=$!
  for _ in $(seq 1 50); do
    [[ -S "${TPM_DIR}/sock" ]] && return 0
    sleep 0.1
  done
  echo "swtpm did not start" >&2
  return 1
}

qemu() {
  qemu-system-x86_64 \
    -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${VARS}" \
    -chardev "socket,id=chrtpm,path=${TPM_DIR}/sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -drive "file=${DISK},if=none,id=nvm,format=qcow2" -device nvme,serial=GVPNVM0001,drive=nvm \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=n0 \
    "$@"
}

cmd_install() {
  local iso="${1:?usage: vm.sh install ISO}"
  rm -rf "${VM_DIR}"
  mkdir -p "${VM_DIR}"
  qemu-img create -f qcow2 "${DISK}" 64G >/dev/null
  cp "${OVMF_VARS}" "${VARS}"
  chmod u+w "${VARS}"
  start_swtpm
  echo "installing ${iso} (serial log: ${VM_DIR}/install.log); QEMU exits when the installer reboots"
  qemu -cdrom "${iso}" -boot once=d -no-reboot -display none -serial "file:${VM_DIR}/install.log"
  echo "installed into ${DISK}"
}

cmd_run() {
  [[ -f "${DISK}" ]] || { echo "no VM disk; run: just vm-install" >&2; exit 1; }
  start_swtpm
  echo "booting ${DISK}; ssh: just vm-ssh (port ${SSH_PORT}); quit QEMU with Ctrl-a x"
  qemu -nographic
}

cmd_run_headless() {
  [[ -f "${DISK}" ]] || { echo "no VM disk; run: just vm-install" >&2; exit 1; }
  start_swtpm
  echo "booting ${DISK} headless; console: ${VM_DIR}/console.log; ssh port ${SSH_PORT}"
  qemu -display none -serial "file:${VM_DIR}/console.log"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  run) cmd_run ;;
  run-headless) cmd_run_headless ;;
  *) echo "usage: ${0} install ISO | run | run-headless" >&2; exit 64 ;;
esac
