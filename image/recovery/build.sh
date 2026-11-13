#!/usr/bin/env bash
# Build the recovery stick's Unified Kernel Image inside the pinned base image.
#
#   image/recovery/build.sh OUTPUT_DIR
#
# Runs in quay.io/fedora/fedora-iot (image/versions.env) with this repository
# mounted at /src; tools/build-recovery.sh starts it. Nothing here ever runs on
# an appliance: the result is one EFI binary that tools/recovery-usb.sh writes
# to a FAT stick, which someone on site boots once (docs/recovery.md).
#
# Fedora's dracut cannot leave systemd out of this initrd (see below), so
# systemd is PID 1 and runs the module's dracut hooks. Kernel modules are
# restricted to the storage an appliance needs, because one firmware blob would
# outweigh the rest of the image. The byte budget in
# image/recovery/versions.env catches either growing.
#
# image/recovery/kernel-cmdline is baked into the image. Its last console= is
# tty0 because the kernel makes the last one /dev/console, where the verdict
# for the person on site is printed; rd.shell=0 and rd.emergency=poweroff make
# any failure the script did not catch power off instead of opening a root
# shell.
set -euo pipefail

src=/src
out="${1:-/out}"
budget="${GVPN_RECOVERY_MAX_BYTES:?set it from RECOVERY_MAX_BYTES in image/recovery/versions.env}"
kernel_cmdline="$(<"${src}/image/recovery/kernel-cmdline")"

die() {
  echo "$*" >&2
  exit 1
}

[[ "$(uname -m)" == x86_64 ]] || die "built on $(uname -m); the stick boots BOOTX64.EFI on x86_64 appliances (tools/build-recovery.sh pins linux/amd64)"

kver="$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -n1)"
[[ -n "${kver}" ]] || die "no kernel under /lib/modules"
vmlinuz="/usr/lib/modules/${kver}/vmlinuz"
[[ -f "${vmlinuz}" ]] || vmlinuz="/boot/vmlinuz-${kver}"
[[ -f "${vmlinuz}" ]] || die "no vmlinuz for ${kver}"
echo "kernel ${kver}: ${vmlinuz}"

package_manager() {
  local pm
  for pm in dnf5 dnf microdnf; do
    if command -v "${pm}" >/dev/null; then
      printf '%s\n' "${pm}"
      return 0
    fi
  done
  die "no package manager in the base image"
}
# systemd-boot-unsigned ships the EFI stub (linuxx64.efi.stub) ukify wraps
# the kernel in; systemd-ukify does not pull it in.
"$(package_manager)" install -y dracut busybox xfsprogs util-linux coreutils systemd-ukify systemd-boot-unsigned binutils xz cpio

install -D -m 0755 "${src}/image/recovery/gvpn-recovery.sh" /usr/libexec/gvpn-recovery.sh
rm -rf /usr/lib/dracut/modules.d/95gvpn-recovery
install -d /usr/lib/dracut/modules.d/95gvpn-recovery
install -m 0755 "${src}"/image/recovery/modules.d/95gvpn-recovery/*.sh /usr/lib/dracut/modules.d/95gvpn-recovery/

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
initrd="${work}/initrd.img"

# Fedora's dracut always carries systemd-udevd, which depends on the systemd
# module, so a shell initrd without systemd is not reachable through dracut
# here; omitting systemd-initrd alone leaves dracut's unit dependencies broken.
# What is left to control is the bulk: no generic kernel module set (it drags
# every module and firmware blob in), no networking, no storage stacks this
# appliance does not use, and no disk encryption or network-bound unlocking
# (clevis is pulled in by the default set and cannot work without crypt, which
# is omitted, so naming it keeps dracut from reporting the dependency).
omit_modules="kernel-modules kernel-modules-extra network network-legacy nfs nfs4 iscsi lvm dm mdraid multipath crypt fido2 tpm2-tss systemd-cryptsetup systemd-pcrphase systemd-battery-check ignition-edge journal-conf ssh-client clevis clevis-pin-file clevis-pin-null clevis-pin-sss clevis-pin-tang clevis-pin-tpm2"

# dracut copies /root into the initrd when it is a symlink, and in the ostree
# layout of the base image it points at /var/roothome, which the container image
# does not carry: the copy fails with "installing '/root'" and dracut exits 0
# anyway. Create the directory the appliance has, so the layout the build sees
# is the layout of a real device.
install -d -m 0700 /var/roothome

dracut_log="${work}/dracut.log"
if ! dracut --force --no-hostonly --no-hostonly-cmdline \
  --kver "${kver}" \
  --omit "${omit_modules}" \
  --add "gvpn-recovery" \
  --force-drivers "xfs fat vfat msdos nvme nvme-core ahci libahci sd_mod usb-storage uas xhci-pci xhci-hcd" \
  --kernel-cmdline "${kernel_cmdline}" \
  "${initrd}" 2>&1 | tee "${dracut_log}"; then
  die "dracut failed; see its output above"
fi

# dracut reports a missing file or module as an error and still exits 0, so a
# file the recovery script needs could be absent from the stick without the
# build noticing. Everything it reports as a failure stops the build; the one
# line that is expected is the missing syslog socket, because the build
# container has no syslog to log to.
unexpected="$(grep -E '^(dracut\[E\]|dracut-install: ERROR)' "${dracut_log}" \
  | grep -vE "^dracut\[E\]: No '/dev/log' or 'logger' included" || true)"
[[ -z "${unexpected}" ]] || die "dracut reported a problem:
${unexpected}"

# lsinitrd lists paths relative to the initramfs root, without a leading slash.
contents="$(lsinitrd "${initrd}")"
grep -q 'usr/libexec/gvpn-recovery.sh' <<<"${contents}" || die "the recovery script is missing from the initrd"
# The storage drivers pull a few small firmware files (regulatory.db and the
# like); the wireless and GPU families are what must never appear, and the byte
# budget catches anything else that grows.
for family in iwlwifi amdgpu nvidia rtlwifi brcmfmac; do
  if grep -qE "/firmware/${family}" <<<"${contents}"; then
    die "the initrd carries ${family} firmware; restrict the drivers"
  fi
done
firmware_files="$(awk '/firmware\// { total += 1 } END { print total + 0 }' <<<"${contents}")"

mkdir -p "${out}"
ukify build \
  --linux "${vmlinuz}" \
  --initrd "${initrd}" \
  --cmdline "${kernel_cmdline}" \
  --uname "${kver}" \
  --output "${out}/BOOTX64.EFI" \
  >/dev/null

size="$(stat -c %s "${out}/BOOTX64.EFI")"
initrd_size="$(stat -c %s "${initrd}")"
vmlinuz_size="$(stat -c %s "${vmlinuz}")"
printf 'vmlinuz %8d bytes\ninitrd  %8d bytes\nUKI     %8d bytes (budget %d)\n' \
  "${vmlinuz_size}" "${initrd_size}" "${size}" "${budget}"
((size <= budget)) || die "the image is ${size} bytes, over the ${budget} byte budget in image/recovery/versions.env"

(
  cd "${out}"
  sha256sum BOOTX64.EFI >SHA256SUMS
)
{
  printf 'kernel: %s\n' "${kver}"
  printf 'built: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'vmlinuz bytes: %s\ninitrd bytes: %s\nimage bytes: %s\n' "${vmlinuz_size}" "${initrd_size}" "${size}"
  printf 'initrd firmware files: %s\n' "${firmware_files}"
} >"${out}/build.txt"
cat "${out}/build.txt"
