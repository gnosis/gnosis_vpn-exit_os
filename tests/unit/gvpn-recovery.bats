#!/usr/bin/env bats
# gvpn-recovery.sh is the whole recovery run: find the appliance, add the
# operator keys, open the support window, write the report and power off.
#
# The phases run against a fake appliance root and a fake stick, so every path
# stays a plain directory and no mount or root privilege is involved.

load helpers

RECOVERY="${REPO_ROOT}/image/recovery/gvpn-recovery.sh"
NOW=1790220600 # 2026-09-24T03:30:00Z; the window then runs to 2026-10-01

setup() {
  setup_sandbox
  export GVPN_RECOVERY_ROOT="${SANDBOX}/root"
  export GVPN_RECOVERY_STICK="${SANDBOX}/stick"
  export GVPN_RECOVERY_RUN_DIR="${SANDBOX}/run"
  export GVPN_RECOVERY_CONSOLE="${SANDBOX}/console.log"
  export GVPN_RECOVERY_NOW="${NOW}"
  export GVPN_RECOVERY_ASSUME_MOUNTED=1
  export GVPN_RECOVERY_NO_POWEROFF=1
  export GVPN_RECOVERY_HOLD=0
  : >"${GVPN_RECOVERY_CONSOLE}"

  # The appliance's root partition as the stick mounts it: an ostree system
  # keeps /var and each deployment's /etc and /usr under
  # ostree/deploy/<stateroot>/, never at the top of the partition.
  STATEROOT="${GVPN_RECOVERY_ROOT}/ostree/deploy/default"
  VAR="${STATEROOT}/var"
  DEPLOY="${STATEROOT}/deploy/1a2b3c.0"
  mkdir -p "${DEPLOY}/etc/gvpn-exit" \
    "${DEPLOY}/etc/ssh" \
    "${DEPLOY}/usr/lib" \
    "${VAR}/home/devops/.ssh" \
    "${VAR}/lib/gvpn-exit/identity" \
    "${VAR}/lib/gvpn-exit/state" \
    "${GVPN_RECOVERY_STICK}/gvpn-recovery"
  touch "${DEPLOY}.origin"
  chmod 0700 "${VAR}/home/devops" "${VAR}/home/devops/.ssh"

  echo 'SER8X0000000001' >"${VAR}/lib/gvpn-exit/identity/serial"
  cat >"${VAR}/lib/gvpn-exit/identity/node.json" <<'EOF'
{"node_address": "0xf8ac", "support_public_key": "ssh-ed25519 AAAAsupport gvpn-exit-support-SER8X0000000001"}
EOF
  cat >"${DEPLOY}/etc/gvpn-exit/support.env" <<'EOF'
SUPPORT_PORT=22001
BASTION=ops@bastion.example.org
EOF
  echo 'ssh-ed25519 AAAAhostkey gvpn-exit-host' >"${DEPLOY}/etc/ssh/ssh_host_ed25519_key.pub"
  echo 'VERSION="v1.2.3"' >"${DEPLOY}/usr/lib/os-release"
  echo 'ssh-ed25519 AAAApresent installer@laptop' >"${VAR}/home/devops/.ssh/authorized_keys"
  chmod 0600 "${VAR}/home/devops/.ssh/authorized_keys"

  cat >"${GVPN_RECOVERY_STICK}/gvpn-recovery/authorized_keys" <<'EOF'
# rendered by the bastion inventory
ssh-ed25519 AAAApresent installer@laptop
ssh-ed25519 AAAAoperator1 ops@workstation
sk-ssh-ed25519@openssh.com AAAAoperator2 yk ncf
EOF
  mock_cmd chown
  mock_cmd chcon
}

teardown() {
  teardown_sandbox
}

key_file() {
  printf '%s\n' "${VAR}/home/devops/.ssh/authorized_keys"
}

report() {
  cat "${GVPN_RECOVERY_STICK}/gvpn-recovery/report.txt"
}

# absent PATTERN FILE
# Fails when PATTERN is in FILE. A bare `! grep` only counts as the last line
# of a test: bash's errexit ignores a negated command anywhere else.
absent() {
  if grep -q -- "$1" "$2"; then
    return 1
  fi
}

@test "run adds the missing keys with an expiry and keeps the file private" {
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  grep -q 'AAAAoperator1' "$(key_file)"
  grep -q 'AAAAoperator2' "$(key_file)"
  grep -qE '^expiry-time="20261001Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20260924$' "$(key_file)"
  [ "$(stat -c %a "$(key_file)")" = "600" ]
  [ "$(grep -c AAAAoperator1 "$(key_file)")" -eq 1 ]
}

# A keys file saved on Windows carries CRLF. Without stripping it the blob
# keeps a stray carriage return, sshd refuses the line, and the run still
# reports success.
@test "a keys file with CRLF line endings yields usable keys" {
  printf 'ssh-ed25519 AAAAoperator1 ops@workstation\r\n' >"${GVPN_RECOVERY_STICK}/gvpn-recovery/authorized_keys"

  run "${RECOVERY}" run

  [ "${status}" -eq 0 ]
  grep -qxE 'expiry-time="20261001Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20260924' "$(key_file)"
  absent $'\r' "$(key_file)"
}

@test "run leaves an existing key alone and never duplicates it" {
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  [ "$(grep -c AAAApresent "$(key_file)")" -eq 1 ]
  absent 'expiry-time.*AAAApresent' "$(key_file)"
}

@test "run opens the support window and records the recovery request" {
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  [ "$(cat "${VAR}/lib/gvpn-exit/state/support-until")" = "2026-10-01T03:30:00Z" ]
  [ "$(cat "${VAR}/lib/gvpn-exit/state/recovery-request")" = "7" ]
}

@test "run writes the report the support team needs" {
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  report | grep -q '^device serial: SER8X0000000001$'
  report | grep -q '^bastion: ops@bastion.example.org$'
  report | grep -q '^support port: 22001$'
  report | grep -q '^support public key: ssh-ed25519 AAAAsupport'
  report | grep -q '^device host key: ssh-ed25519 AAAAhostkey'
  report | grep -q '^keys added: 2$'
  report | grep -q '^result: OK$'
}

@test "run shows the success screen with the next steps" {
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  grep -q 'GnosisVPN recovery: SUCCESS' "${GVPN_RECOVERY_CONSOLE}"
  grep -q 'Remove the USB stick' "${GVPN_RECOVERY_CONSOLE}"
  grep -q 'Hold the power button' "${GVPN_RECOVERY_CONSOLE}"
}

@test "the verdict stays on screen before the device turns off" {
  export GVPN_RECOVERY_HOLD=600
  mock_cmd sleep
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  calls | grep -qx 'sleep 600'
  grep -q 'turns off by itself in 10 minutes' "${GVPN_RECOVERY_CONSOLE}"
}

@test "a refusal also stays on screen before the device turns off" {
  export GVPN_RECOVERY_HOLD=600
  mock_cmd sleep
  rm "${GVPN_RECOVERY_STICK}/gvpn-recovery/authorized_keys"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  calls | grep -qx 'sleep 600'
}

@test "a second run changes nothing and says so" {
  "${RECOVERY}" run
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  [ "$(grep -c AAAAoperator1 "$(key_file)")" -eq 1 ]
  grep -q 'GnosisVPN recovery: ALREADY APPLIED' "${GVPN_RECOVERY_CONSOLE}"
}

@test "a key file that group or others can write is refused" {
  chmod 0666 "$(key_file)"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  absent AAAAoperator1 "$(key_file)"
  grep -q 'STOPPED' "${GVPN_RECOVERY_CONSOLE}"
  grep -q 'SSH key file is not secured' "${GVPN_RECOVERY_CONSOLE}"
  [ ! -e "${VAR}/lib/gvpn-exit/state/recovery-request" ]
}

@test "a key whose earlier recovery line has expired is granted again" {
  echo 'expiry-time="20260101Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20251225' >>"$(key_file)"
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  [ "$(grep -c AAAAoperator1 "$(key_file)")" -eq 1 ]
  grep -qE '^expiry-time="20261001Z" ssh-ed25519 AAAAoperator1 gvpn-recovery-20260924$' "$(key_file)"
  report | grep -q '^keys added: 2$'
}

@test "a recovery line for a key the stick no longer carries is removed" {
  echo 'expiry-time="20261230Z" ssh-ed25519 AAAAgone gvpn-recovery-20260920' >>"$(key_file)"
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  absent AAAAgone "$(key_file)"
  grep -q AAAApresent "$(key_file)"
}

@test "a commented-out key does not count as present" {
  echo '# ssh-ed25519 AAAAoperator1 disabled' >>"$(key_file)"
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  grep -q '^# ssh-ed25519 AAAAoperator1 disabled$' "$(key_file)"
  grep -qE '^expiry-time="20261001Z" ssh-ed25519 AAAAoperator1 ' "$(key_file)"
}

@test "rewriting the key file keeps its inode, so owner, mode and label stay" {
  local inode
  inode="$(stat -c %i "$(key_file)")"
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  [ "$(stat -c %i "$(key_file)")" = "${inode}" ]
}

@test "the key file is owned like the devops home, not by a fixed uid" {
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  calls | grep -qx "chown $(stat -c %u:%g "${VAR}/home/devops") $(key_file)"
  absent '1000:1000' "${MOCK_LOG}"
}

@test "a key file that cannot be written fails loudly instead of reporting success" {
  chmod 0400 "$(key_file)"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  grep -q 'FAILED' "${GVPN_RECOVERY_CONSOLE}"
  absent 'SUCCESS' "${GVPN_RECOVERY_CONSOLE}"
}

@test "a support window that cannot be written fails loudly" {
  chmod 0555 "${VAR}/lib/gvpn-exit/state"
  run "${RECOVERY}" run
  chmod 0755 "${VAR}/lib/gvpn-exit/state"
  [ "${status}" -eq 1 ]
  grep -q 'FAILED' "${GVPN_RECOVERY_CONSOLE}"
  absent 'SUCCESS' "${GVPN_RECOVERY_CONSOLE}"
}

@test "a report the stick cannot take is a warning on the success screen" {
  chmod 0555 "${GVPN_RECOVERY_STICK}/gvpn-recovery"
  run "${RECOVERY}" run
  chmod 0755 "${GVPN_RECOVERY_STICK}/gvpn-recovery"
  [ "${status}" -eq 0 ]
  grep -q 'SUCCESS' "${GVPN_RECOVERY_CONSOLE}"
  grep -q 'Warning: the report could not be saved' "${GVPN_RECOVERY_CONSOLE}"
}

@test "a created key file that cannot be labelled is a warning, on screen and in the report" {
  rm "$(key_file)"
  mock_cmd chcon 'exit 1'
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  grep -q 'Warning: the SSH key file has no SELinux label' "${GVPN_RECOVERY_CONSOLE}"
  report | grep -q '^warning: the SSH key file has no SELinux label'
}

@test "the report names the kernel the stick booted" {
  mock_cmd uname 'echo 6.17.1-300.fc44.x86_64'
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  report | grep -q '^stick kernel: 6.17.1-300.fc44.x86_64$'
}

@test "the kernel command line puts the verdict on the screen and never offers a shell" {
  local cmdline consoles
  cmdline="$(cat "${REPO_ROOT}/image/recovery/kernel-cmdline")"
  # The last console= becomes /dev/console, where the verdict is printed.
  consoles="$(tr ' ' '\n' <<<"${cmdline}" | grep '^console=')"
  [ "$(tail -n1 <<<"${consoles}")" = console=tty0 ]
  [[ " ${cmdline} " == *" rd.shell=0 "* ]]
  [[ " ${cmdline} " == *" rd.emergency=poweroff "* ]]
}

@test "the kernel command line names no root device for the initrd to wait for" {
  local cmdline root
  cmdline="$(cat "${REPO_ROOT}/image/recovery/kernel-cmdline")"
  # A root=/dev/... makes dracut's and systemd's generators require that
  # device, so the initrd would hang waiting for it instead of reaching
  # pre-pivot. root=tmpfs gives /sysroot a tmpfs, so the appliance root must
  # be mounted somewhere else.
  [[ " ${cmdline} " == *" root=tmpfs "* ]]
  root="$(env -u GVPN_RECOVERY_ROOT bash -c 'source "$1"; echo "${ROOT}"' _ "${RECOVERY}")"
  [ "${root}" != /sysroot ]
}

# install_calls
# What the dracut module's install() asks dracut to put into the initrd, one
# "FUNCTION ARGS..." line per call.
install_calls() {
  bash -c '
    inst_hook() { echo "inst_hook $*"; }
    inst_simple() { echo "inst_simple $*"; }
    inst_multiple() { :; }
    moddir=/mod
    source "$1"
    install
  ' _ "${REPO_ROOT}/image/recovery/modules.d/95gvpn-recovery/module-setup.sh"
}

@test "the dracut module installs its hooks where dracut runs them" {
  run install_calls
  [ "${status}" -eq 0 ]
  grep -qx 'inst_hook pre-mount [0-9]* /mod/pre-mount.sh' <<<"${output}"
  grep -qx 'inst_hook pre-pivot 99 /mod/pre-pivot.sh' <<<"${output}"
  # Only inst_hook knows dracut's hook directory.
  [[ "${output}" != *"inst_simple /mod/pre-"* ]]
}

# Run a dracut hook the way dracut does: sourced by /bin/sh, without errexit.
hook() {
  GVPN_RECOVERY_SCRIPT="${RECOVERY}" sh -c '. "$1"' _ \
    "${REPO_ROOT}/image/recovery/modules.d/95gvpn-recovery/$1.sh"
}

@test "the pre-pivot hook shows success after a successful apply" {
  hook pre-mount
  run hook pre-pivot
  grep -q 'GnosisVPN recovery: SUCCESS' "${GVPN_RECOVERY_CONSOLE}"
  absent 'FAILED' "${GVPN_RECOVERY_CONSOLE}"
}

@test "the pre-pivot hook never shows success when apply fails" {
  hook pre-mount
  rm -rf "${VAR}/home/devops"
  run hook pre-pivot
  grep -q 'GnosisVPN recovery: FAILED' "${GVPN_RECOVERY_CONSOLE}"
  absent 'SUCCESS' "${GVPN_RECOVERY_CONSOLE}"
}

@test "the pre-mount hook shows a failure when prepare fails unexpectedly" {
  chmod 0555 "${GVPN_RECOVERY_RUN_DIR}"
  run hook pre-mount
  chmod 0755 "${GVPN_RECOVERY_RUN_DIR}"
  grep -q 'GnosisVPN recovery: FAILED' "${GVPN_RECOVERY_CONSOLE}"
}

@test "prepare waits for the stick to show up" {
  unset GVPN_RECOVERY_ASSUME_MOUNTED
  echo 0 >"${SANDBOX}/blkid-calls"
  # The stick's label resolves on the third lookup.
  mock_cmd blkid 'case "$*" in
    *-L*) n=$(($(cat "${SANDBOX}/blkid-calls") + 1)); echo "${n}" >"${SANDBOX}/blkid-calls"
      ((n >= 3)) && echo /dev/sdz1 ;;
    *) echo xfs ;;
  esac'
  mock_cmd lsblk 'exit 0'
  mock_cmd mount
  mock_cmd udevadm
  mock_cmd sleep
  run "${RECOVERY}" prepare
  [ "${status}" -eq 1 ]
  absent 'not recognised' "${GVPN_RECOVERY_CONSOLE}"
  grep -q 'No GnosisVPN device found' "${GVPN_RECOVERY_CONSOLE}"
  calls | grep -q '^udevadm settle'
}

@test "a stick that never shows up is refused after the wait" {
  unset GVPN_RECOVERY_ASSUME_MOUNTED
  export GVPN_RECOVERY_WAIT=3
  mock_cmd blkid 'exit 2'
  mock_cmd sleep
  run "${RECOVERY}" prepare
  [ "${status}" -eq 1 ]
  grep -q 'This USB stick was not recognised' "${GVPN_RECOVERY_CONSOLE}"
  [ "$(calls | grep -cx 'sleep 1')" -eq 3 ]
}

@test "a stick without its payload is refused" {
  rm "${GVPN_RECOVERY_STICK}/gvpn-recovery/authorized_keys"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  absent AAAAoperator1 "$(key_file)"
}

@test "a stick that carries no usable key is refused" {
  echo 'not a key' >"${GVPN_RECOVERY_STICK}/gvpn-recovery/authorized_keys"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  absent AAAAoperator1 "$(key_file)"
}

@test "a missing key file is created and labelled from .ssh" {
  rm "$(key_file)"
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  grep -q AAAAoperator1 "$(key_file)"
  [ "$(stat -c %a "$(key_file)")" = "600" ]
  calls | grep -q "^chcon --reference=${VAR}/home/devops/.ssh"
}

@test "a root without a gvpn-exit identity is refused" {
  rm "${VAR}/lib/gvpn-exit/identity/serial"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  grep -q 'not a GnosisVPN device' "${GVPN_RECOVERY_CONSOLE}"
}

@test "identification refuses when no disk looks like an appliance" {
  unset GVPN_RECOVERY_ASSUME_MOUNTED
  mock_cmd lsblk 'case "$*" in *PKNAME*) exit 0 ;; *) exit 0 ;; esac'
  mock_cmd blkid 'case "$*" in *-L*) echo /dev/sdz1 ;; *) echo xfs ;; esac'
  mock_cmd mount 'exit 0'
  mock_cmd umount
  run "${RECOVERY}" prepare
  [ "${status}" -eq 1 ]
  grep -q 'No GnosisVPN device found' "${GVPN_RECOVERY_CONSOLE}"
}

@test "identification refuses two disks that both look like appliances" {
  unset GVPN_RECOVERY_ASSUME_MOUNTED
  rm -rf "${GVPN_RECOVERY_ROOT}/ostree"
  mock_cmd lsblk 'case "$*" in
    *PKNAME*) case "$*" in *sdz1*) echo sdz ;; *) echo sdx ;; esac ;;
    *) printf "/dev/sdx1 part\n/dev/sdy2 part\n" ;;
  esac'
  mock_cmd blkid 'case "$*" in *-L*) echo /dev/sdz1 ;; *) echo xfs ;; esac'
  mock_cmd mount 'mkdir -p "$4/ostree/deploy/default/var/lib/gvpn-exit/identity"; echo S >"$4/ostree/deploy/default/var/lib/gvpn-exit/identity/serial"'
  mock_cmd umount
  run "${RECOVERY}" prepare
  [ "${status}" -eq 1 ]
  grep -q 'More than one disk looks like a device' "${GVPN_RECOVERY_CONSOLE}"
}

@test "identification reads lsblk's partitions, not its tree drawing" {
  unset GVPN_RECOVERY_ASSUME_MOUNTED
  rm -rf "${GVPN_RECOVERY_ROOT}/ostree"
  # Real lsblk: a tree unless -l asks for a list, even with -n.
  mock_cmd lsblk 'case "$*" in
    *PKNAME*) case "$*" in *sdz1*) echo sdz ;; *) echo nvme0n1 ;; esac ;;
    *-l*) printf "/dev/nvme0n1 disk\n/dev/nvme0n1p3 part\n" ;;
    *) printf "/dev/nvme0n1 disk\n\`-/dev/nvme0n1p3 part\n" ;;
  esac'
  mock_cmd blkid 'case "$*" in *-L*) echo /dev/sdz1 ;; *) echo xfs ;; esac'
  mock_cmd mount 'mkdir -p "$4/ostree/deploy/default/var/lib/gvpn-exit/identity"; echo S3 >"$4/ostree/deploy/default/var/lib/gvpn-exit/identity/serial"'
  mock_cmd umount 'rm -rf "$1/ostree"'
  mock_cmd udevadm
  run "${RECOVERY}" prepare
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_RECOVERY_RUN_DIR}/dev")" = /dev/nvme0n1p3 ]
}

@test "identification picks the partition whose stateroot carries the identity" {
  unset GVPN_RECOVERY_ASSUME_MOUNTED
  rm -rf "${GVPN_RECOVERY_ROOT}/ostree"
  # nvme0n1p2 is /boot: ostree content, but no stateroot /var.
  mock_cmd lsblk 'case "$*" in
    *PKNAME*) case "$*" in *sdz1*) echo sdz ;; *) echo nvme0n1 ;; esac ;;
    *) printf "/dev/nvme0n1p2 part\n/dev/nvme0n1p3 part\n" ;;
  esac'
  mock_cmd blkid 'case "$*" in *-L*) echo /dev/sdz1 ;; *) echo xfs ;; esac'
  mock_cmd mount 'mkdir -p "$4/ostree/boot.1"
    if [[ "$3" == /dev/nvme0n1p3 ]]; then
      mkdir -p "$4/ostree/deploy/default/var/lib/gvpn-exit/identity"
      echo S3 >"$4/ostree/deploy/default/var/lib/gvpn-exit/identity/serial"
    fi'
  mock_cmd umount 'rm -rf "$1/ostree"'
  run "${RECOVERY}" prepare
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_RECOVERY_RUN_DIR}/dev")" = /dev/nvme0n1p3 ]
  [ "$(cat "${GVPN_RECOVERY_RUN_DIR}/serial")" = S3 ]
}

@test "an identity outside the ostree stateroot is not an appliance" {
  mkdir -p "${GVPN_RECOVERY_ROOT}/var/lib/gvpn-exit/identity"
  mv "${VAR}/lib/gvpn-exit/identity/serial" "${GVPN_RECOVERY_ROOT}/var/lib/gvpn-exit/identity/serial"
  run "${RECOVERY}" run
  [ "${status}" -eq 1 ]
  grep -q 'not a GnosisVPN device' "${GVPN_RECOVERY_CONSOLE}"
}

@test "the report reads /etc and /usr from the newest deployment" {
  local older="${STATEROOT}/deploy/9f8e7d.1"
  mkdir -p "${older}/etc/gvpn-exit" "${older}/usr/lib"
  echo 'VERSION="v1.2.2"' >"${older}/usr/lib/os-release"
  echo 'BASTION=old@bastion.example.org' >"${older}/etc/gvpn-exit/support.env"
  touch -d '2026-01-01T00:00:00Z' "${older}.origin"
  touch -d '2026-09-01T00:00:00Z' "${DEPLOY}.origin"
  run "${RECOVERY}" run
  [ "${status}" -eq 0 ]
  report | grep -q '^device image: v1.2.3$'
  report | grep -q '^bastion: ops@bastion.example.org$'
}
