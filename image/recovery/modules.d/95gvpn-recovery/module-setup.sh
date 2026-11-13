#!/usr/bin/env bash
# shellcheck disable=SC2154 # moddir is set by dracut's build
# dracut module: run the recovery stick's logic from the initramfs.
#
# Only image/recovery/build.sh adds this module (`dracut --add gvpn-recovery`),
# so it is never part of the appliance image. systemd is PID 1 in this initrd
# (image/recovery/build.sh) and runs the hooks below as dracut's services.
# root=tmpfs (image/recovery/kernel-cmdline) gives the initrd no root device
# to wait for, so the pre-mount hook itself waits for the stick and lets udev
# settle before it looks for the appliance.

check() {
  require_binaries mount umount blkid lsblk stat date chown chmod base64 \
    sha256sum awk grep sed head cp cat sync sleep uname poweroff udevadm || return 1
  return 0
}

depends() {
  echo busybox
}

installkernel() {
  # Only the storage an appliance needs: NVMe, SATA for older boards, the
  # stick's own USB storage and the filesystems this script mounts. Anything
  # wider drags in firmware blobs that dwarf the rest of the image.
  instmods xfs vfat msdos fat nvme nvme-core sd_mod ahci libahci usb-storage uas xhci-pci xhci-hcd
}

install() {
  inst_multiple mount umount blkid lsblk findmnt stat date chown chmod chcon \
    base64 sha256sum awk grep sed head cp cat sync sleep uname poweroff udevadm
  inst_simple /usr/libexec/gvpn-recovery.sh /usr/libexec/gvpn-recovery.sh
  inst_hook pre-mount 95 "${moddir}/pre-mount.sh"
  # Last pre-pivot hook, so nothing else runs before the appliance powers off.
  inst_hook pre-pivot 99 "${moddir}/pre-pivot.sh"
}
