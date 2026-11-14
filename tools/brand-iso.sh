#!/usr/bin/env bash
# Drop the Fedora release from the installer ISO's boot menu. Runs on the host
# after tools/build-disk.sh, with xorriso, mtools and isomd5sum from the Linux
# devshell.
#
#   tools/brand-iso.sh ISO
#
# bootc-image-builder titles the menu "Install NAME VERSION_ID" from the
# image's os-release and has no setting for it. NAME is GnosisVPN ExitOS
# (image/build/brand-os-release.sh), but VERSION_ID stays Fedora's because it
# selects the installer's packages, so the menu read "Install GnosisVPN ExitOS
# 44". The ISO carries the menu three times: /EFI/BOOT/grub.cfg,
# /boot/grub2/grub.cfg for BIOS, and EFI/BOOT/grub.cfg in the appended EFI
# system partition, which UEFI firmware boots from a stick and through El
# Torito. xorriso writes the ISO again with its own boot equipment replayed and
# the patched partition in place of the old one, implantisomd5 embeds the
# checksum that the "Test this media" entry verifies again, and the sha256 in
# the ISO's target sidecar follows the new ISO.
set -euo pipefail

iso="${1:?usage: brand-iso.sh ISO}"
name="GnosisVPN ExitOS"
menus=(/EFI/BOOT/grub.cfg /boot/grub2/grub.cfg)

# Beside the ISO, so the new one replaces it by a rename; 0700, so the ISO's
# enrollment key is not readable while it is being written.
work="$(mktemp -d "$(dirname "${iso}")/.brand-iso-XXXXXX")"
trap 'rm -rf "${work}"' EXIT

# Run a tool and show what it printed only when it fails.
quiet() {
  local out
  out="$("$@" 2>&1)" || { printf '%s\n' "${out}" >&2; return 1; }
}

mkdir "${work}/boot"
quiet xorriso -osirrox on -indev "${iso}" -extract_boot_images "${work}/boot" \
  -extract "${menus[0]}" "${work}/efi.cfg" -extract "${menus[1]}" "${work}/bios.cfg"
esp="${work}/boot/gpt_part2_efi.img"
mtype -i "${esp}" ::/EFI/BOOT/grub.cfg > "${work}/esp.cfg"

for menu in efi bios esp; do
  sed -i "s/\(${name}\) [0-9][0-9.]*/\1/g" "${work}/${menu}.cfg"
  grep -q "^menuentry 'Install ${name}' " "${work}/${menu}.cfg" || {
    echo "${iso}: the ${menu} boot menu has no 'Install ${name}' entry" >&2
    exit 1
  }
done
quiet mcopy -o -i "${esp}" "${work}/esp.cfg" ::/EFI/BOOT/grub.cfg

part_type="$(xorriso -indev "${iso}" -report_el_torito as_mkisofs 2>/dev/null \
  | sed -n 's/^-append_partition 2 \([^ ]*\) .*/\1/p')"
[[ -n "${part_type}" ]] || {
  echo "${iso} has no appended EFI system partition" >&2
  exit 1
}
quiet xorriso -indev "${iso}" -outdev "${work}/branded.iso" -boot_image any replay \
  -append_partition 2 "${part_type}" "${esp}" \
  -map "${work}/efi.cfg" "${menus[0]}" -map "${work}/bios.cfg" "${menus[1]}" \
  -chown 0 "${menus[@]}" -- -chgrp 0 "${menus[@]}" -- -chmod 0644 "${menus[@]}" --
quiet implantisomd5 --force "${work}/branded.iso"
chmod --reference="${iso}" "${work}/branded.iso"
mv "${work}/branded.iso" "${iso}"

if [[ -e "${iso}.target" ]]; then
  sed -i "s/^sha256=.*/sha256=$(sha256sum "${iso}" | cut -d' ' -f1)/" "${iso}.target"
fi
