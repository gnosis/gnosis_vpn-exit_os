#!/usr/bin/env bats
# image/bib/select-install-disk.sh runs as the installer ISO's kickstart %pre
# and picks the disk the install wipes: the only internal disk, never the
# installer media or a removable stick. Anything else stops the install.

load helpers

SELECT="${REPO_ROOT}/image/bib/select-install-disk.sh"

# The installer runs it with its own /bin/bash; run it with the devshell's
# bash, since macOS ships a /bin/bash without mapfile.
select_disk() {
  bash "${SELECT}"
}

setup() {
  setup_sandbox
  export GVPN_DISK_KS="${SANDBOX}/gvpn-install-disk.ks"
  export GVPN_INSTALL_MEDIA="${SANDBOX}/repo"
  DISKS="${SANDBOX}/lsblk.disks"
  : > "${DISKS}"
  # lsblk -dnro NAME,TYPE,RM,RO,TRAN prints the disk list; lsblk -no PKNAME
  # SOURCE prints the parent of the partition the media is mounted from.
  mock_cmd lsblk "
case \"\$1\" in
  -dnro) cat '${DISKS}' ;;
  -no) cat '${SANDBOX}/lsblk.pkname' 2>/dev/null || true ;;
esac"
  # No installer media mounted unless a test says otherwise.
  mock_cmd findmnt "exit 1"
}

teardown() {
  teardown_sandbox
}

# disks LINE...: the raw lsblk listing, one "NAME TYPE RM RO TRAN" per line.
disks() {
  printf '%s\n' "$@" > "${DISKS}"
}

# media_on SOURCE [PKNAME]: the installer media is mounted from SOURCE, whose
# parent disk is PKNAME (empty for a whole disk).
media_on() {
  mock_cmd findmnt "echo '$1'"
  echo "${2:-}" > "${SANDBOX}/lsblk.pkname"
}

assert_chosen() {
  [ "${status}" -eq 0 ]
  [ "$(cat "${GVPN_DISK_KS}")" = "$(printf 'ignoredisk --only-use=%s\nclearpart --all --initlabel --disklabel=gpt --drives=%s' "$1" "$1")" ]
}

@test "hardware: the single NVMe disk is chosen" {
  disks "nvme0n1 disk 0 0 nvme" "zram0 disk 0 0 "
  run select_disk
  assert_chosen nvme0n1
}

@test "Incus VM: the single sda is chosen, the ISO on sr0 is not a disk" {
  disks "sda disk 0 0 sata" "sr0 rom 1 0 sata"
  media_on /dev/sr0
  run select_disk
  assert_chosen sda
}

@test "a USB stick is never a candidate, by transport or by removable flag" {
  disks "nvme0n1 disk 0 0 nvme" "sdb disk 0 0 usb" "sdc disk 1 0 "
  run select_disk
  assert_chosen nvme0n1
}

@test "the disk holding the installer media is excluded even when it looks internal" {
  disks "nvme0n1 disk 0 0 nvme" "sdb disk 0 0 sata"
  media_on /dev/sdb1 sdb
  run select_disk
  assert_chosen nvme0n1
  grep -qx "findmnt -no SOURCE ${GVPN_INSTALL_MEDIA}" <<< "$(calls)"
}

@test "media mounted from a whole disk excludes that disk" {
  disks "sda disk 0 0 sata" "sdb disk 0 0 sata"
  media_on /dev/sdb
  run select_disk
  assert_chosen sda
}

@test "read-only disks, zram and loop devices are ignored" {
  disks "loop0 loop 0 1 " "loop1 disk 0 0 " "zram0 disk 0 0 " "vda disk 0 0 virtio" "vdb disk 0 1 virtio"
  run select_disk
  assert_chosen vda
}

@test "two internal disks: refuses, names both and how to pin one" {
  disks "nvme0n1 disk 0 0 nvme" "sda disk 0 0 sata"
  run select_disk
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"found 2 internal disks (nvme0n1 sda)"* ]]
  [[ "${output}" == *"GVPN_INSTALL_DISK="* ]]
  [ ! -e "${GVPN_DISK_KS}" ]
}

@test "no internal disk: refuses and writes nothing" {
  disks "sdb disk 1 0 usb" "sr0 rom 1 0 sata"
  run select_disk
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"found 0 internal disks"* ]]
  [[ "${output}" == *"GVPN_INSTALL_DISK="* ]]
  [ ! -e "${GVPN_DISK_KS}" ]
}

# The script is embedded in a TOML basic multi-line string, where a backslash
# starts an escape and three double quotes end the string, and in a kickstart
# section, which a line starting with % ends.
@test "the script holds no backslash, no triple quote, no % line and no template marker" {
  run grep -c '[\\]' "${SELECT}"
  [ "${output}" = 0 ]
  run grep -c '"""' "${SELECT}"
  [ "${output}" = 0 ]
  run grep -c '^%' "${SELECT}"
  [ "${output}" = 0 ]
  run grep -c '@[A-Z_]*@' "${SELECT}"
  [ "${output}" = 0 ]
}

@test "the script is executable" {
  [ -x "${SELECT}" ]
}
