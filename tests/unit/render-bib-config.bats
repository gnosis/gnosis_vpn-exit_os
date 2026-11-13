#!/usr/bin/env bats
# tools/render-bib-config.sh renders the bootc-image-builder config on the
# host. The installer ISO carries the devops key and, when the operator gives
# the bastion inputs, everything the enrollment tunnel needs for first access;
# the QEMU qcow2 only the key.

load helpers

RENDER="${REPO_ROOT}/tools/render-bib-config.sh"

setup() {
  setup_sandbox
  unset GVPN_CONSOLE_ACCESS
  PUBKEY="${SANDBOX}/devops.pub"
  echo "ssh-ed25519 AAAAC3NzaDevops ops@example" > "${PUBKEY}"
  export GVPN_BASTION="support@bastion.example"
  export GVPN_SUPPORT_PORT=22001
  export GVPN_ENROLL_KEY="${SANDBOX}/enroll"
  export GVPN_BASTION_KNOWN_HOSTS="${SANDBOX}/known_hosts"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END OPENSSH PRIVATE KEY-----\n' > "${GVPN_ENROLL_KEY}"
  echo "bastion.example ssh-ed25519 AAAAC3NzaBastion" > "${GVPN_BASTION_KNOWN_HOSTS}"
}

teardown() {
  teardown_sandbox
}

# Decode the file the rendered %post writes to /etc/gvpn-exit/NAME.
post_file() {
  grep "> /etc/gvpn-exit/$1" <<< "${output}" | cut -d"'" -f2 | base64 -d
}

@test "iso: the installer writes the enrollment tunnel config in %post" {
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  [ "$(post_file support.env)" = "$(printf 'SUPPORT_PORT=22001\nBASTION=support@bastion.example')" ]
  [ "$(post_file bastion_known_hosts)" = "$(cat "${GVPN_BASTION_KNOWN_HOSTS}")" ]
  [ "$(post_file enroll.key)" = "$(cat "${GVPN_ENROLL_KEY}")" ]
}

@test "iso: the enrollment key is written readable by root only" {
  run "${RENDER}" iso "${PUBKEY}"
  grep -q "^(umask 077; echo '.*' | base64 -d > /etc/gvpn-exit/enroll.key)$" <<< "${output}"
}

@test "iso: the devops key goes to the kickstart and no placeholder is left" {
  run "${RENDER}" iso "${PUBKEY}"
  grep -qx 'sshkey --username=devops "ssh-ed25519 AAAAC3NzaDevops"' <<< "${output}"
  run grep '@[A-Z_]*@' <<< "${output}"
  [ "${status}" -eq 1 ]
}

@test "iso: pins the partitions and lets / take the whole remaining disk" {
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -qx 'part /boot/efi --fstype=efi --size=600' <<< "${output}"
  grep -qx 'part /boot --fstype=xfs --size=2048' <<< "${output}"
  grep -qx 'part / --fstype=xfs --grow' <<< "${output}"
  run grep -q '^autopart' <<< "${output}"
  [ "${status}" -eq 1 ]
}

@test "iso: a bastion with a non-default SSH port is accepted as an ssh:// URI" {
  export GVPN_BASTION="ssh://support@bastion.example:2200"
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  [[ "$(post_file support.env)" == *"BASTION=ssh://support@bastion.example:2200" ]]
}

# The four bastion inputs come as a set: an ISO that carries a key but no
# bastion, or a bastion but no key, would install a device nobody can reach
# the way its operator expects.
@test "iso: refuses a partial set of bastion inputs and says which one is unset" {
  unset GVPN_BASTION
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_BASTION"*"(unset)"* ]]
  export GVPN_BASTION="support@bastion.example"
  unset GVPN_ENROLL_KEY
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_ENROLL_KEY"*"(unset)"* ]]
}

@test "iso: without bastion inputs the installer carries no enrollment key and no tunnel config" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"%post"* ]]
  # The only section left is the disk selection %pre.
  [ "$(grep -c '^%end$' <<< "${output}")" -eq 1 ]
  [[ "${output}" != *"enroll.key"* ]]
  [[ "${output}" != *"support.env"* ]]
  # LAN access is all this device has: the devops key and the locked passwords
  # stay, and the kickstart is still closed properly.
  grep -qx 'sshkey --username=devops "ssh-ed25519 AAAAC3NzaDevops"' <<< "${output}"
  grep -qx 'rootpw --lock' <<< "${output}"
  grep -qx 'reboot --eject' <<< "${output}"
  [ "$(tail -1 <<< "${output}")" = '"""' ]
  run grep '@[A-Z_]*@' <<< "${output}"
  [ "${status}" -eq 1 ]
}

@test "iso: inputs that are set but empty count as no bastion" {
  export GVPN_BASTION="" GVPN_SUPPORT_PORT="" GVPN_ENROLL_KEY="" GVPN_BASTION_KNOWN_HOSTS=""
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"%post"* ]]
}

@test "iso: the install disk is validated without bastion inputs too" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  GVPN_INSTALL_DISK=sda run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -q 'ignoredisk --only-use=sda' <<< "${output}"
  GVPN_INSTALL_DISK='sda; rm -rf /' run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_INSTALL_DISK"* ]]
}

@test "iso: names the rejected bastion value" {
  export GVPN_BASTION="bastion.example"
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"'bastion.example'"* ]]
}

@test "iso: a port on the bastion needs the ssh:// form" {
  export GVPN_BASTION="support@bastion.example:2200"
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
}

# A leading zero makes bash read the port as octal, which is not a number and
# used to slip past the range check.
@test "iso: refuses a reverse port with a leading zero" {
  for port in 08080 022001; do
    GVPN_SUPPORT_PORT="${port}" run "${RENDER}" iso "${PUBKEY}"
    [ "${status}" -ne 0 ] || { echo "accepted port ${port}"; false; }
    [[ "${output}" == *"GVPN_SUPPORT_PORT"* ]]
  done
}

# One ISO serves hardware and VMs, whose disks differ: by default the installer
# picks the disk in %pre and the kickstart includes what it wrote.
@test "iso: by default the installer picks the disk it wipes" {
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  rendered="${output}"
  grep -qx '%include /tmp/gvpn-install-disk.ks' <<< "${rendered}"
  grep -qx '%pre --interpreter=/bin/bash --erroronfail' <<< "${rendered}"
  # The %pre body is the selection script, verbatim.
  [ "$(sed -n '/^%pre /,/^%end$/p' <<< "${rendered}" | sed '1d;$d')" = "$(cat "${REPO_ROOT}/image/bib/select-install-disk.sh")" ]
  run grep -E '^(ignoredisk|clearpart) ' <<< "${rendered}"
  [ "${status}" -eq 1 ]
  [[ "${rendered}" != *"/dev/auto"* ]]
  run grep '@[A-Z_]*@' <<< "${rendered}"
  [ "${status}" -eq 1 ]
}

@test "iso: a named disk is pinned in the kickstart, with no %pre" {
  GVPN_INSTALL_DISK=sda run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -qx 'ignoredisk --only-use=sda' <<< "${output}"
  grep -qx 'clearpart --all --initlabel --disklabel=gpt --drives=sda' <<< "${output}"
  grep -q '/dev/sda' <<< "${output}"
  [[ "${output}" != *"%pre"* ]]
  [[ "${output}" != *"%include"* ]]
  [[ "${output}" != *"gvpn-install-disk"* ]]
  run grep '@[A-Z_]*@' <<< "${output}"
  [ "${status}" -eq 1 ]
  GVPN_INSTALL_DISK='sda; rm -rf /' run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
}

# The kickstart is a TOML basic multi-line string, where a backslash starts an
# escape sequence.
@test "iso: the rendered config holds no backslash" {
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  run grep -c '[\\]' <<< "${output}"
  [ "${output}" = 0 ]
  export GVPN_CONSOLE_ACCESS=1
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  run grep -c '[\\]' <<< "${output}"
  [ "${output}" = 0 ]
}

@test "iso: refuses a reverse port outside 1024-65535" {
  for port in 80 70000 abc ""; do
    GVPN_SUPPORT_PORT="${port}" run "${RENDER}" iso "${PUBKEY}"
    [ "${status}" -ne 0 ] || { echo "accepted port '${port}'"; false; }
  done
}

@test "iso: refuses an enrollment key that is not an OpenSSH private key" {
  cp "${PUBKEY}" "${GVPN_ENROLL_KEY}"
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_ENROLL_KEY"* ]]
}

@test "iso: refuses an empty bastion known_hosts" {
  : > "${GVPN_BASTION_KNOWN_HOSTS}"
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"GVPN_BASTION_KNOWN_HOSTS"* ]]
}

@test "iso: console access ignores the key file and installs no SSH key" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  rm -f "${PUBKEY}"
  export GVPN_CONSOLE_ACCESS=1
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  rendered="${output}"
  grep -qx 'user --name=devops --groups=wheel --iscrypted --password "$6$gvpn-exit$j7xn4gZetDeh6pNrgXd18GpRvr7xK2BLHpuv51nmGRgtL1K4dUBEV15ePl7UPapwA1WYpTApHXlgCPGWVQOJK0"' <<< "${rendered}"
  run grep -q 'sshkey --username=devops' <<< "${rendered}"
  [ "${status}" -eq 1 ]
  grep -q 'chage -d 0 devops' <<< "${rendered}"
  grep -q 'systemctl enable serial-getty@ttyS0.service' <<< "${rendered}"
  run grep '@[A-Z_]*@' <<< "${rendered}"
  [ "${status}" -eq 1 ]
}

# incus console attaches to the serial port; hardware has a keyboard and a
# monitor, and a getty on a serial port that is not there restarts in a loop.
@test "iso: console access enables the serial getty only in a VM" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  export GVPN_CONSOLE_ACCESS=1
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  [ "$(grep -A2 -x 'if systemd-detect-virt --quiet --vm; then' <<< "${output}" | sed 's/^ *//')" = "$(printf 'if systemd-detect-virt --quiet --vm; then\nsystemctl enable serial-getty@ttyS0.service\nfi')" ]
  [ "$(grep -c 'serial-getty@ttyS0' <<< "${output}")" -eq 1 ]
}

@test "iso: the console password hash matches the documented password" {
  command -v openssl >/dev/null || skip "openssl is not on PATH"
  run openssl passwd -6 -salt gvpn-exit gvpn-exit
  [ "${status}" -eq 0 ]
  [[ "${output}" == '$6$gvpn-exit$j7xn4gZetDeh6pNrgXd18GpRvr7xK2BLHpuv51nmGRgtL1K4dUBEV15ePl7UPapwA1WYpTApHXlgCPGWVQOJK0' ]]
}

@test "iso: key access has no console password or serial getty block" {
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  rendered="${output}"
  grep -qx 'user --name=devops --groups=wheel --lock' <<< "${rendered}"
  run grep -q 'chage -d 0 devops' <<< "${rendered}"
  [ "${status}" -eq 1 ]
  run grep -q 'serial-getty@ttyS0' <<< "${rendered}"
  [ "${status}" -eq 1 ]
}

@test "qcow2: needs no enrollment inputs and carries no %post" {
  unset GVPN_BASTION GVPN_SUPPORT_PORT GVPN_ENROLL_KEY GVPN_BASTION_KNOWN_HOSTS
  run "${RENDER}" qcow2 "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -qx 'key = "ssh-ed25519 AAAAC3NzaDevops"' <<< "${output}"
  [[ "${output}" != *"%post"* ]]
}

@test "refuses a devops key that is not an SSH public key" {
  echo "not a key" > "${PUBKEY}"
  run "${RENDER}" qcow2 "${PUBKEY}"
  [ "${status}" -ne 0 ]
}

@test "usage error on an unknown kind" {
  run "${RENDER}" raw "${PUBKEY}"
  [ "${status}" -eq 64 ]
}

@test "the key comment is dropped, so no quote or sed metacharacter reaches the config" {
  echo 'ssh-ed25519 AAAAC3NzaDevops ops "workstation" a&b\c' > "${PUBKEY}"
  run "${RENDER}" qcow2 "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -qx 'key = "ssh-ed25519 AAAAC3NzaDevops"' <<< "${output}"
  run "${RENDER}" iso "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -qx 'sshkey --username=devops "ssh-ed25519 AAAAC3NzaDevops"' <<< "${output}"
}

@test "a key comment cannot inject sed commands" {
  echo "ssh-ed25519 AAAAC3NzaDevops x|;w ${SANDBOX}/injected" > "${PUBKEY}"
  run "${RENDER}" qcow2 "${PUBKEY}"
  [ "${status}" -eq 0 ]
  [ -z "$(ls "${SANDBOX}" | grep injected)" ]
}

@test "accepts the security-key types the recovery stick accepts" {
  echo 'sk-ssh-ed25519@openssh.com AAAAC3NzaDevops ops@yubikey' > "${PUBKEY}"
  run "${RENDER}" qcow2 "${PUBKEY}"
  [ "${status}" -eq 0 ]
  grep -qx 'key = "sk-ssh-ed25519@openssh.com AAAAC3NzaDevops"' <<< "${output}"
}

@test "refuses a devops key whose key data is not base64" {
  echo 'ssh-ed25519 AAAA"C3Nza ops@example' > "${PUBKEY}"
  run "${RENDER}" qcow2 "${PUBKEY}"
  [ "${status}" -ne 0 ]
}
