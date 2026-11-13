#!/bin/bash
# Pick the disk the unattended installer wipes, so one ISO serves hardware and
# VMs. Runs as the installer ISO's kickstart %pre (tools/render-bib-config.sh
# embeds it verbatim) and writes the ignoredisk and clearpart commands the
# kickstart includes. The candidate is the only whole internal disk: not
# removable, not read-only, not on USB, and not the disk the installer media
# is on. With none or several it writes nothing and fails, which stops the
# install before anything is wiped; GVPN_INSTALL_DISK at ISO build time pins
# the disk instead.
#
# The kickstart lives in a TOML basic string, so this file holds no backslash.
#   GVPN_INSTALL_MEDIA  where the installer media is mounted (/run/install/repo)
#   GVPN_DISK_KS        the kickstart snippet written (/tmp/gvpn-install-disk.ks)
set -euo pipefail

INSTALL_MEDIA="${GVPN_INSTALL_MEDIA:-/run/install/repo}"
DISK_KS="${GVPN_DISK_KS:-/tmp/gvpn-install-disk.ks}"
# NVMe namespaces, SCSI/SATA and virtio disks; zram, loop, md and the like
# are never install targets.
DISK_NAME_RE='^(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+)$'

# The whole disk the installer media is on, empty when the media is not
# mounted.
media_disk() {
  local source parent
  source="$(findmnt -no SOURCE "${INSTALL_MEDIA}" 2>/dev/null)" || return 0
  [[ -n "${source}" ]] || return 0
  parent="$(lsblk -no PKNAME "${source}" 2>/dev/null | head -1)" || parent=""
  parent="${parent// /}"
  # No parent: the media is a whole disk itself (a CD-ROM, an unpartitioned
  # stick).
  if [[ -n "${parent}" ]]; then
    echo "${parent}"
  else
    echo "${source##*/}"
  fi
}

# Print the candidate disks, one name per line.
candidate_disks() {
  local media listing name type rm ro tran
  media="$(media_disk)"
  listing="$(lsblk -dnro NAME,TYPE,RM,RO,TRAN)"
  while read -r name type rm ro tran; do
    [[ "${type}" == disk && "${rm}" == 0 && "${ro}" == 0 && "${tran}" != usb ]] || continue
    [[ "${name}" =~ ${DISK_NAME_RE} ]] || continue
    [[ "${name}" != "${media}" ]] || continue
    echo "${name}"
  done <<< "${listing}"
}

main() {
  local found disks=()
  found="$(candidate_disks)"
  [[ -z "${found}" ]] || mapfile -t disks <<< "${found}"
  if (( ${#disks[@]} != 1 )); then
    echo "gvpn-exit installer: found ${#disks[@]} internal disks (${disks[*]:-none}), need exactly one to install to." >&2
    echo "Nothing was wiped. Build the ISO with GVPN_INSTALL_DISK=<disk> to name the disk to install to." >&2
    exit 1
  fi
  {
    echo "ignoredisk --only-use=${disks[0]}"
    echo "clearpart --all --initlabel --disklabel=gpt --drives=${disks[0]}"
  } > "${DISK_KS}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
