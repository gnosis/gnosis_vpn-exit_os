#!/usr/bin/env bats
# tools/brand-iso.sh drops the Fedora release from the installer ISO's boot
# menu. The fixture is a small ISO laid out like bootc-image-builder's: the
# menu in /EFI/BOOT/grub.cfg, in /boot/grub2/grub.cfg for BIOS (with an entry
# of its own), and in the appended EFI system partition that El Torito's UEFI
# entry boots, plus the checksum the "Test this media" entry checks.

load helpers

BRAND_ISO="${REPO_ROOT}/tools/brand-iso.sh"

setup() {
  setup_sandbox
  for tool in xorriso implantisomd5 checkisomd5; do
    command -v "${tool}" >/dev/null || skip "${tool} is in the Linux devshell only"
  done
  ISO="${SANDBOX}/out/bootiso/install.iso"
  mkdir -p "$(dirname "${ISO}")"
}

teardown() {
  teardown_sandbox
}

# The UEFI menu as bootc-image-builder writes it, with PRODUCT and, after it in
# each title that carries one, VERSION (" 44", or "" for the branded menu).
efi_menu() {
  local product="$1" version="$2"
  cat <<EOF
search --no-floppy --set=root -l 'Fedora-S-dvd-x86_64-44'

menuentry 'Install ${product}${version}' --class fedora --class gnu-linux --class gnu --class os {
	linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.ks=hd:LABEL=Fedora-S-dvd-x86_64-44:/osbuild.ks quiet
	initrd /images/pxeboot/initrd.img
}

menuentry 'Test this media & install ${product}${version}' --class fedora --class gnu-linux --class gnu --class os {
	linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.ks=hd:LABEL=Fedora-S-dvd-x86_64-44:/osbuild.ks rd.live.check quiet
	initrd /images/pxeboot/initrd.img
}

submenu 'Troubleshooting -->' {
	menuentry 'Install ${product}${version} in basic graphics mode' --class fedora --class gnu-linux --class gnu --class os {
		linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.ks=hd:LABEL=Fedora-S-dvd-x86_64-44:/osbuild.ks nomodeset quiet
		initrd /images/pxeboot/initrd.img
	}
	menuentry 'Rescue a ${product} system' --class fedora --class gnu-linux --class gnu --class os {
		linux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-S-dvd-x86_64-44 inst.ks=hd:LABEL=Fedora-S-dvd-x86_64-44:/osbuild.ks inst.rescue quiet
		initrd /images/pxeboot/initrd.img
	}
}
EOF
}

bios_menu() {
  efi_menu "$@"
  cat <<'EOF'
menuentry 'Boot first drive' --class fedora --class gnu-linux --class gnu --class os {
	chainloader (hd0)+1
}
EOF
}

# make_iso PRODUCT: the fixture ISO with an implanted checksum, 0600 like an
# ISO that carries the enrollment key, and the target sidecar build-disk.sh
# writes beside it.
make_iso() {
  local tree="${SANDBOX}/tree" esp="${SANDBOX}/esp.img"
  mkdir -p "${tree}/EFI/BOOT" "${tree}/boot/grub2"
  efi_menu "$1" ' 44' > "${tree}/EFI/BOOT/grub.cfg"
  bios_menu "$1" ' 44' > "${tree}/boot/grub2/grub.cfg"
  mkfs.fat -C "${esp}" 4096 >/dev/null
  mmd -i "${esp}" ::/EFI ::/EFI/BOOT
  mcopy -i "${esp}" "${tree}/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg
  xorriso -as mkisofs -quiet -V 'Fedora-S-dvd-x86_64-44' -o "${ISO}" \
    -append_partition 2 0xef "${esp}" -appended_part_as_gpt \
    -e --interval:appended_partition_2:all:: -no-emul-boot "${tree}" 2>/dev/null
  implantisomd5 "${ISO}" >/dev/null
  chmod 0600 "${ISO}"
  printf 'disk=auto\nenrollment=bastion\naccess=key\nchannel=stable\nimage=sha256:1d1d1d\nsha256=%s\n' \
    "$(sha256sum "${ISO}" | cut -d' ' -f1)" > "${ISO}.target"
}

# The three copies of the menu and the boot equipment, read back from the ISO.
extract_iso() {
  local out="${SANDBOX}/extracted"
  rm -rf "${out}"
  mkdir -p "${out}/boot"
  xorriso -osirrox on -indev "${ISO}" -extract_boot_images "${out}/boot" \
    -extract /EFI/BOOT/grub.cfg "${out}/efi.cfg" \
    -extract /boot/grub2/grub.cfg "${out}/bios.cfg" 2>/dev/null
  mtype -i "${out}/boot/gpt_part2_efi.img" ::/EFI/BOOT/grub.cfg > "${out}/esp.cfg"
}

@test "drops the Fedora release from every copy of the installer menu" {
  make_iso "GnosisVPN ExitOS"
  run "${BRAND_ISO}" "${ISO}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  extract_iso
  # The titles lose the release; the volume label that carries it too stays.
  diff <(efi_menu "GnosisVPN ExitOS" "") "${SANDBOX}/extracted/efi.cfg"
  diff <(efi_menu "GnosisVPN ExitOS" "") "${SANDBOX}/extracted/esp.cfg"
  diff <(bios_menu "GnosisVPN ExitOS" "") "${SANDBOX}/extracted/bios.cfg"
}

@test "the branded ISO keeps its boot equipment, label and media check" {
  make_iso "GnosisVPN ExitOS"
  run "${BRAND_ISO}" "${ISO}"
  [ "${status}" -eq 0 ]
  extract_iso
  report="$(xorriso -indev "${ISO}" -report_el_torito as_mkisofs 2>/dev/null)"
  grep -qx -- "-V 'Fedora-S-dvd-x86_64-44'" <<< "${report}"
  grep -q -- "^-append_partition 2 " <<< "${report}"
  # UEFI firmware boots El Torito's EFI image: it has to be the patched
  # partition, not a copy of the one bootc-image-builder wrote.
  grep -q -- "^-e '--interval:appended_partition_2" <<< "${report}"
  cmp "${SANDBOX}/extracted/boot/eltorito_img1_uefi.img" "${SANDBOX}/extracted/boot/gpt_part2_efi.img"
  checkisomd5 "${ISO}" >/dev/null 2>&1
}

@test "the branded ISO keeps its mode and its target sidecar describes it" {
  make_iso "GnosisVPN ExitOS"
  before="$(grep -v '^sha256=' "${ISO}.target")"
  run "${BRAND_ISO}" "${ISO}"
  [ "${status}" -eq 0 ]
  [ "$(stat -c %a "${ISO}")" = "600" ]
  grep -qx "sha256=$(sha256sum "${ISO}" | cut -d' ' -f1)" "${ISO}.target"
  [ "$(grep -v '^sha256=' "${ISO}.target")" = "${before}" ]
  # Nothing of the work is left beside the ISO.
  [ "$(ls -A "$(dirname "${ISO}")")" = "$(printf 'install.iso\ninstall.iso.target')" ]
}

@test "refuses a menu that does not name GnosisVPN ExitOS and leaves the ISO as it was" {
  make_iso "Fedora Linux"
  sum="$(sha256sum "${ISO}")"
  target="$(cat "${ISO}.target")"
  run "${BRAND_ISO}" "${ISO}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Install GnosisVPN ExitOS"* ]]
  [ "$(sha256sum "${ISO}")" = "${sum}" ]
  [ "$(cat "${ISO}.target")" = "${target}" ]
  [ "$(ls -A "$(dirname "${ISO}")")" = "$(printf 'install.iso\ninstall.iso.target')" ]
}
