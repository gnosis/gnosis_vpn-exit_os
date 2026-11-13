#!/usr/bin/env bats
# tools/incus.sh installs the appliance ISO into an Incus VM for operators who
# do not have the hardware at hand. The VM needs a vTPM for provisioning and a
# virtio-scsi root disk, which is /dev/sda; the installer detects that disk or
# is pinned to it.

load helpers

INCUS="${REPO_ROOT}/tools/incus.sh"

setup() {
  setup_sandbox
  # The rehearsal exports VM_SSH_KEY in the same shell; tests set what they need.
  unset VM_SSH_KEY GVPN_INCUS_VM GVPN_INCUS_CPUS GVPN_INCUS_MEMORY GVPN_INCUS_DISK_SIZE GVPN_INCUS_INSTALL_DISK
  ISO="${SANDBOX}/install.iso"
  echo 'iso' >"${ISO}"
  export MOCK_INCUS_IP="10.20.30.40"
  export MOCK_INCUS_EXTRA=""
  export MOCK_STOP_FAIL=""
  export GVPN_INCUS_IP_WAIT=0
  mock_cmd incus '
case "$1" in
  info) [[ -e "${SANDBOX}/instance" ]] ;;
  init) touch "${SANDBOX}/instance" ;;
  start) touch "${SANDBOX}/running" ;;
  stop)
    if [[ -n "${MOCK_STOP_FAIL:-}" && "$3" == --timeout=60 ]]; then exit 1; fi
    rm -f "${SANDBOX}/running" ;;
  list)
    status=Stopped
    [[ -e "${SANDBOX}/running" ]] && status=Running
    extra=""
    [[ -n "${MOCK_INCUS_EXTRA:-}" ]] && extra="${MOCK_INCUS_EXTRA},"
    printf "[%s{\"name\":\"%s\",\"status\":\"%s\",\"state\":{\"network\":{\"eth0\":{\"addresses\":[{\"family\":\"inet\",\"scope\":\"global\",\"address\":\"%s\"}]}}}}]\n" "${extra}" "${GVPN_INCUS_VM:-gvpn-exit}" "${status}" "${MOCK_INCUS_IP:-}" ;;
  config)
    case "$3" in
      list) [[ -e "${SANDBOX}/install-device" ]] && echo install ;;
      add) if [[ "$5" == install ]]; then touch "${SANDBOX}/install-device"; fi ;;
      remove) if [[ "$5" == install ]]; then rm -f "${SANDBOX}/install-device"; fi ;;
    esac ;;
  *) : ;;
esac'
  mock_cmd ssh
}

teardown() {
  teardown_sandbox
}

@test "an empty instance becomes an UEFI VM with a vTPM and the installer first" {
  run "${INCUS}" install "${ISO}"
  [ "${status}" -eq 0 ]
  grep -qx 'incus init gvpn-exit --empty --vm -c limits.cpu=8 -c limits.memory=16GiB -c security.secureboot=false -d root,size=64GiB -d root,boot.priority=10' "${MOCK_LOG}"
  grep -qx 'incus config device add gvpn-exit tpm tpm' "${MOCK_LOG}"
  grep -qx "incus config device add gvpn-exit install disk source=$(realpath "${ISO}") boot.priority=5" "${MOCK_LOG}"
  grep -qx 'incus start gvpn-exit --console' "${MOCK_LOG}"
  [[ "${output}" == *"Ctrl-a q"* ]]
}

@test "the VM name and size are inputs" {
  GVPN_INCUS_VM=exit-vm GVPN_INCUS_CPUS=2 GVPN_INCUS_MEMORY=2GiB GVPN_INCUS_DISK_SIZE=32GiB \
    run "${INCUS}" install "${ISO}"
  [ "${status}" -eq 0 ]
  grep -qx 'incus init exit-vm --empty --vm -c limits.cpu=2 -c limits.memory=2GiB -c security.secureboot=false -d root,size=32GiB -d root,boot.priority=10' "${MOCK_LOG}"
}

@test "install refuses to take over an existing instance" {
  touch "${SANDBOX}/instance"
  run "${INCUS}" install "${ISO}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"already exists"* ]]
  run grep '^incus init ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "install names the missing ISO" {
  rm "${ISO}"
  run "${INCUS}" install "${ISO}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no installer ISO"* ]]
  run grep '^incus init ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "run stops the installer, detaches the ISO and boots the disk" {
  touch "${SANDBOX}/instance" "${SANDBOX}/install-device" "${SANDBOX}/running"
  run "${INCUS}" run
  [ "${status}" -eq 0 ]
  grep -qx 'incus stop gvpn-exit --timeout=60' "${MOCK_LOG}"
  grep -qx 'incus config device remove gvpn-exit install' "${MOCK_LOG}"
  grep -qx 'incus start gvpn-exit' "${MOCK_LOG}"
  [[ "${output}" == *"devops@10.20.30.40"* ]]
}

@test "ip picks the exact instance name, not a longer prefix" {
  touch "${SANDBOX}/instance"
  export MOCK_INCUS_EXTRA='{"name":"gvpn-exit-2","status":"Running","state":{"network":{"eth0":{"addresses":[{"family":"inet","scope":"global","address":"10.99.99.99"}]}}}}'
  run "${INCUS}" ip
  [ "${status}" -eq 0 ]
  [ "${output}" = "10.20.30.40" ]
}

@test "run falls back to force when the graceful stop fails" {
  touch "${SANDBOX}/instance" "${SANDBOX}/install-device" "${SANDBOX}/running"
  export MOCK_STOP_FAIL=1
  run "${INCUS}" run
  [ "${status}" -eq 0 ]
  grep -qx 'incus stop gvpn-exit --timeout=60' "${MOCK_LOG}"
  grep -qx 'incus stop gvpn-exit --force' "${MOCK_LOG}"
  grep -qx 'incus config device remove gvpn-exit install' "${MOCK_LOG}"
}

@test "run leaves a running installed VM alone and does not force-stop it" {
  touch "${SANDBOX}/instance" "${SANDBOX}/running"
  run "${INCUS}" run
  [ "${status}" -eq 0 ]
  run grep '^incus stop ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
  run grep '^incus config device remove ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "install refuses an ISO pinned to another disk" {
  { echo disk=nvme0n1; echo enrollment=none; } >"${ISO}.target"
  run "${INCUS}" install "${ISO}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"nvme0n1"* ]]
  [[ "${output}" == *"just iso"* ]]
  [[ "${output}" == *"GVPN_INSTALL_DISK=sda just iso"* ]]
  run grep '^incus init ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "install accepts an ISO that detects its disk" {
  { echo disk=auto; echo enrollment=none; } >"${ISO}.target"
  run "${INCUS}" install "${ISO}"
  [ "${status}" -eq 0 ]
  grep -q '^incus init ' "${MOCK_LOG}"
}

@test "install accepts a vda ISO when the VM disk is configured that way" {
  { echo disk=vda; echo enrollment=none; } >"${ISO}.target"
  GVPN_INCUS_INSTALL_DISK=vda run "${INCUS}" install "${ISO}"
  [ "${status}" -eq 0 ]
}

# A relative path names a file below the caller's directory, not below the
# repository the script changes into; the sandbox keeps the repository clean.
@test "install resolves the ISO to an absolute path for incusd" {
  mkdir -p "${SANDBOX}/isos"
  echo iso >"${SANDBOX}/isos/install.iso"
  cd "${SANDBOX}"
  run "${INCUS}" install isos/install.iso
  [ "${status}" -eq 0 ]
  grep -q "install disk source=$(realpath "${SANDBOX}/isos/install.iso") boot.priority=5" "${MOCK_LOG}"
}

@test "run without an instance points at incus-install" {
  run "${INCUS}" run
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"just incus-install"* ]]
  run grep '^incus start ' "${MOCK_LOG}"
  [ "${status}" -eq 1 ]
}

@test "ip prints the bridge address Incus learned" {
  touch "${SANDBOX}/instance"
  run "${INCUS}" ip
  [ "${status}" -eq 0 ]
  [ "${output}" = "10.20.30.40" ]
}

@test "ip fails clearly while the VM has no address" {
  touch "${SANDBOX}/instance"
  export MOCK_INCUS_IP=""
  run "${INCUS}" ip
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no IPv4 address"* ]]
}

@test "ssh connects as devops to the resolved address and forwards arguments" {
  touch "${SANDBOX}/instance"
  run "${INCUS}" ssh sudo gvpn-exit-status
  [ "${status}" -eq 0 ]
  grep -qx 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null devops@10.20.30.40 sudo gvpn-exit-status' "${MOCK_LOG}"
}

@test "ssh uses VM_SSH_KEY when it is set" {
  touch "${SANDBOX}/instance"
  export VM_SSH_KEY="/secure/devops-key"
  run "${INCUS}" ssh true
  [ "${status}" -eq 0 ]
  grep -qx 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /secure/devops-key devops@10.20.30.40 true' "${MOCK_LOG}"
}

@test "console attaches to the instance" {
  touch "${SANDBOX}/instance"
  run "${INCUS}" console
  [ "${status}" -eq 0 ]
  grep -qx 'incus console gvpn-exit' "${MOCK_LOG}"
}

@test "destroy deletes the instance and its vTPM" {
  touch "${SANDBOX}/instance"
  run "${INCUS}" destroy
  [ "${status}" -eq 0 ]
  grep -qx 'incus delete gvpn-exit --force' "${MOCK_LOG}"
}

@test "usage error on an unknown command" {
  run "${INCUS}" raw
  [ "${status}" -eq 64 ]
}
