# Recovery stick

What to hand someone on site when an appliance answers no SSH key any more.

A device installed from a key-configured ISO locks both the root and the
devops password ([first-install.md](first-install.md) step 4) and its sshd
accepts `devops` with a key only, so a keyboard and monitor at the device are
not a way in. Neither is the bastion: it only forwards to the device's sshd.
A console-configured device, on hardware or in a VM, can be reached on its
console with the `devops` password as long as that password is not locked
([first access on the console](local-access.md#first-access-on-the-console)).
When the keys on a device are wrong or missing, for instance on a device that
never received the operator keys, somebody has to boot this stick.

The stick is a single Unified Kernel Image on a FAT32 ESP, ~60 MB measured
(18 MB kernel, 42 MB initrd). It finds the
appliance, adds the operators' public keys to `devops`, opens a seven-day
support window and writes a report to the stick. It cannot install packages,
repartition, reset passwords or repair a filesystem, and every refusal leaves
the device untouched.

## What it touches

The appliance is an ostree system, and the stick sees its root partition, not
the booted view of it: `/var` is `ostree/deploy/<stateroot>/var` there, and
`/etc` and `/usr` belong to a deployment under
`ostree/deploy/<stateroot>/deploy/`. The stick requires exactly one stateroot
with a gvpn-exit identity and reads the report's `/etc` and `/usr` values from
the most recently deployed deployment.

| Path (as the running device sees it) | Change |
|---|---|
| `/var/home/devops/.ssh/authorized_keys` | one line per operator key that is not present yet, with `expiry-time=` seven days out and the key comment `gvpn-recovery-<date>`; earlier `gvpn-recovery-` lines that expired or whose key left the stick are removed |
| `/var/lib/gvpn-exit/state/support-until` | deadline from the appliance's own clock (best effort) |
| `/var/lib/gvpn-exit/state/recovery-request` | the day count; the timer rewrites the deadline and the key expiry from the trusted clock (below) |
| the stick's `gvpn-recovery/report.txt` | serial, bastion, support port and key, host key, what was added, any warning; a copy is kept as `report-<serial>-<time>.txt` |

Nothing else is written. A key counts as present only on a plain line, without
options and not commented out. The key file is rewritten in place, never
replaced, and its owner and mode are set to `devops` and `0600` on every run,
so the SELinux label is the only thing that stays as the installer left it.

## Why the support window has a marker

`support-tunnel.service` only runs while `state/support-until` is in the future
and the clock is NTP-synchronized. A device that has been off for weeks has no
trustworthy clock, so a stick writing a deadline directly could open a window
that is expired on arrival or, worse, far too long. The stick therefore writes
the day count to `state/recovery-request`, and `support-window.sh` consumes it
at the first NTP-synchronized run: it validates 1-90 days, writes the deadline
from the trusted clock, moves the `expiry-time` of every `gvpn-recovery-` key
line to that deadline, then drops the marker. Nothing reopens remote access
without the device's own clock agreeing, and an RTC that is years behind or
ahead neither expires the keys on arrival nor keeps them for years.

## Building the image

Runs through `tools/builder.sh` like the other build recipes, so it needs a
Linux container host: root with Podman, or a Docker daemon (on an arm64 host
the build runs emulated). Packing the finished image into one file
(`just recovery-image`) is a host-side job and runs on macOS too. The build
always runs the `linux/amd64` base image, because appliances are x86_64; on an
arm64 host that is emulated and takes noticeably longer:

```sh
nix develop -c just recovery-build        # output/recovery/BOOTX64.EFI
```

It builds inside the base image pinned in `image/versions.env`, installs
`dracut`, `busybox` and `systemd-ukify` there, and produces the image with
systemd as PID 1 in the initrd (see below) and only the storage drivers an
appliance needs (XFS, VFAT, NVMe, AHCI, USB storage, xHCI). Firmware blobs
would dwarf the rest of the image, so `image/recovery/build.sh` fails the build
if wireless or GPU firmware appears.

The kernel command line is `image/recovery/kernel-cmdline`. Its last
`console=` is `tty0`, because the kernel makes the last one `/dev/console`,
where the verdict is printed. `rd.shell=0 rd.emergency=poweroff` power the
appliance off on any failure the script did not catch, instead of leaving a
root shell on the screen. `root=tmpfs` gives the initrd an empty `/sysroot`
and no root device to wait for; a `root=/dev/...` would make dracut's and
systemd's generators wait for that device forever. The script therefore waits
for the stick itself, lets udev settle and mounts the appliance at
`/run/gvpn-recovery/root`. The dracut hooks gate the verdict: `finish` prints
SUCCESS only after `apply` succeeded, and any phase that ends without its own
verdict prints FAILED and powers off.

`image/recovery/versions.env` holds the byte budget (72 MiB). The build prints
the three sizes (kernel, initrd, image) and writes `SHA256SUMS` and `build.txt`
next to the artifact; `tools/recovery-usb.sh` refuses an image that has no
`SHA256SUMS` or does not match it.

The size is what Fedora's dracut can produce, not what the job needs. The
kernel is 18 MB; the initrd is 42 MB because dracut's udev module depends on
the `systemd` module, and omitting `systemd-initrd` alone leaves its unit
dependencies broken, so a shell initrd without systemd is not reachable through
dracut on this base. The measured split is in `output/recovery/build.txt`.

Reaching the original 22-30 MB target needs a hand-built busybox initramfs
instead of dracut: busybox (1 MB), the ~2 MB storage module set, an `/init`
that mounts `/proc`, `/sys` and `/dev`, runs `mdev -s`, `modprobe`s the
drivers and then calls `gvpn-recovery.sh`. That is roughly 25 MB in total, at
the cost of owning device settling without udev. It is not implemented here.

The base image digest in `image/versions.env` moves: quay garbage-collects the
manifest behind a tag, and the pinned digest then stops resolving. Bump it
separately when a build fails with `manifest unknown`.

## Writing a stick

The stick is the same for every appliance: it carries the public keys only, and
it applies to whichever GnosisVPN device it finds (no serial file, no per-device
build). Its `authorized_keys` file is a plain OpenSSH `authorized_keys`: one
public key line per person or machine you want to let back in. The stick takes
the key type and blob of a line that starts with them; a trailing comment is
dropped, and a line that starts with options is ignored (so write plain lines,
not `authorized_keys` lines copied from a server). Write it to
`output/recovery/authorized_keys` (or pass a path to `just recovery-image`),
one line per operator key:

```sh
{ cat ~/.ssh/id_ed25519.pub other-operators.pub; } > output/recovery/authorized_keys
```

Write the stick:

```sh
nix develop -c just recovery-usb /dev/sdX            # asks for confirmation, needs sudo
```

`tools/recovery-usb.sh` refuses a disk that is not on USB or has a mounted
partition. It clears every old signature (`wipefs -a`, which also removes the
ISO 9660 volume of a stick that carried the installer), writes one GPT
partition of ESP type (`C12A7328-…`), `mkfs.vfat -F 32 -n GVPNRECOV`, then

```
\EFI\BOOT\BOOTX64.EFI
gvpn-recovery\authorized_keys
```

`sgdisk` and `mkfs.vfat` come from the devshell; the recipe passes its `PATH`
through `sudo`.

The volume label is limited to 11 characters by FAT; `GVPNRECOVERY` does not
fit.

## Sending a stick image to someone on site

When nobody from the team can write the stick, pack it into one file instead.
With the image built and the keys in `output/recovery/`, on Linux or macOS:

```sh
nix develop -c just recovery-image                   # or: just recovery-image path/to/authorized_keys
# output/recovery/gvpn-recovery-<version>.img.xz and .img.xz.sha256
```

`tools/recovery-image.sh` checks the image against `SHA256SUMS` and the keys
like `recovery-usb` does, then builds the same layout in a plain file with
`sgdisk`, `mkfs.fat` and mtools, without root or loop devices, and compresses
it with xz (roughly the size of `BOOTX64.EFI`). Send both files over an
access-controlled link: the image is not secret, but it is an authorization
device (see Security), so do not post it publicly.

The recipient needs only a USB stick of at least 1 GB, whose contents are
lost, and one of:

- **balenaEtcher** (Windows, macOS, Linux): *Flash from file*, pick the
  `.img.xz`, pick the stick, *Flash*. Etcher decompresses and verifies the
  write itself.
- **Rufus** (Windows): pick the stick, *SELECT* the `.img.xz`, *START*.
- Linux: `xz -dc gvpn-recovery-<version>.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync`.

To check the download first: `sha256sum -c gvpn-recovery-<version>.img.xz.sha256`
(Linux), `shasum -a 256 -c …` (macOS), or compare
`Get-FileHash gvpn-recovery-<version>.img.xz` with the file on Windows. Then
continue with the next section.

### Flashing the stick on a Mac

These steps are for the person on site; send them along with the two files.
You need a USB stick of 1 GB or more. **Everything on the stick is erased.**
Use a stick with nothing on it that you want to keep.

1. Download both files to your **Downloads** folder:
   `gvpn-recovery-<version>.img.xz` and `gvpn-recovery-<version>.img.xz.sha256`.
   If the first one arrives as `.img` without `.xz`, Etcher takes that too,
   but skip step 2: the check only fits the `.xz` file.
2. Optional, to check that the download is complete: open **Terminal**
   (Applications → Utilities) and enter

   ```sh
   cd ~/Downloads
   shasum -a 256 -c gvpn-recovery-*.img.xz.sha256
   ```

   It must print `OK`. If it prints `FAILED`, download the file again.
3. Download **balenaEtcher** for macOS from <https://etcher.balena.io> and
   drag it into **Applications**. On an Apple Silicon Mac (M1 or later),
   download the build for Apple Silicon (arm64). Open it; if macOS asks whether
   to open an app downloaded from the internet, click **Open**.
4. Plug in the USB stick.
5. In Etcher, click **Flash from file** and select
   `gvpn-recovery-<version>.img.xz`.
6. Click **Select target** and tick the USB stick. Check its name and size:
   it must be the stick, never your Mac's own disk. Etcher hides internal
   disks by default; do not turn that off.
7. Click **Flash!** and enter your Mac password when macOS asks for it.
8. Wait until Etcher shows **Flash Complete!** (it checks the written stick
   by itself, which takes a minute more).
9. A disk named **GVPNRECOV** may then appear on the desktop. Eject it (drag
   it to the Trash, or click the ⏏ symbol in Finder) and unplug the stick.
   If macOS says *"The disk you inserted was not readable by this computer"*,
   click **Eject**; the stick is fine.

Do not open or change files on the stick. Then continue with the next
section.

Without Etcher, Terminal does the same. Only do this if you know which disk
is the stick, because `dd` writes to whatever disk you name, without asking.
`xz` is not part of macOS; install it with Homebrew (`brew install xz`) first.

```sh
diskutil list external                 # find the stick, e.g. /dev/disk4 (check its size)
diskutil unmountDisk /dev/disk4
xz -dc ~/Downloads/gvpn-recovery-<version>.img.xz | sudo dd of=/dev/rdisk4 bs=4m
diskutil eject /dev/disk4
```

`/dev/rdisk4` is the same disk as `/dev/disk4`, just written faster. `dd`
prints nothing until it is done.

## Running it, on the device

1. Unplug the appliance's power.
2. Plug the stick into a USB port, preferably a rear one.
3. Power on and press F7 (**Del** opens the firmware setup) until the boot menu
   appears, then choose the line that starts with `UEFI:` and the stick's name.
4. Wait up to two minutes.

```
========================================
 GnosisVPN recovery: SUCCESS
========================================
 Device serial: SER8X0000000001
 Keys added: 7
 Support window: until 2026-10-31T09:12:00Z
========================================
 1. Photograph this screen and send it
    to the support team.
 2. Remove the USB stick.
 3. Hold the power button until the
    device turns off.
========================================
 The device turns off by itself in 10 minutes.
```

Every screen, refusals included, stays up for ten minutes
(`GVPN_RECOVERY_HOLD`) so it can be read and photographed; the appliance
disk is already synced and unmounted by then, so holding the power button is
safe. The stick must be removed before the appliance is powered on again,
otherwise it boots the stick again, which is harmless, and says so:

```
 GnosisVPN recovery: ALREADY APPLIED
```

Either screen lists a `Warning:` line for what the run could not do without
undoing the recovery: a report the stick would not take, or a key file the
stick had to create and could not label for SELinux (sshd may then refuse the
keys; the operator has to look).

Every refusal is one screen with one cause, and nothing was changed:

| Screen | Cause |
|---|---|
| `This USB stick was not recognised` | the stick's partition or label is damaged |
| `This USB stick could not be read` | the stick's filesystem will not mount; write it again |
| `This USB stick is incomplete` | `authorized_keys` is missing |
| `This USB stick carries no usable key` | the file holds no public key |
| `No GnosisVPN device found` | no appliance disk is attached or readable |
| `More than one disk looks like a device` | more than one install is present; the operator has to look |
| `This is not a GnosisVPN device` | the disk has no gvpn-exit identity |
| `The device's SSH key file is not secured` | sshd's StrictModes would ignore the key anyway |
| `The device's disk could not be read` | the filesystem needs repair; do not continue |

A failure after the device was opened for writing says so instead:

```
 GnosisVPN recovery: FAILED
 The device's SSH key file could not be written.
 The device may be partly changed.
 Call the support team.
```

## Reading the report, as the operator

An unmanaged device ([the setups](first-install.md#choose-your-setup))
has no `support.env`: the bastion and support port lines of the report are
empty, the support window opens no tunnel, and the next step is a login from
the device's LAN ([local access](local-access.md)). The rest of this section
is for devices with a bastion.

`gvpn-recovery/report.txt` on the stick carries the serial, the bastion and
support port from `support.env`, the device's `support_public_key` from its
provisioning record, its host key line, and how many keys were added. That is
everything needed to admit the device again if the bastion lost its
registration: add its support key to the bastion account's `authorized_keys`
with that device's `permitlisten` port ([bastion](bastion.md)):

```text
restrict,port-forwarding,permitopen="localhost:1",permitlisten="localhost:<port>",command="false" <support key>
```

Then make the grant durable and tidy up:

- Connect through the bastion or the LAN and install the permanent operator
  keys there; the injected keys expire after seven days
  ([adding keys](local-access.md#adding-and-replacing-keys)).
- Close the support window when the work is done: `sudo gvpn-exit-support close`
  on the device (LAN SSH keeps working). It also cancels a recovery request the
  timer has not consumed yet, so the window does not reopen.
- Nothing needs to be cleaned off the stick; rewrite it for the next device.

## Security

The stick carries public keys only, but it is still an authorization device: it
writes root-owned files on any appliance it is booted on, and `devops` has
passwordless sudo. Treat it like a key to the fleet:

- Injected keys carry `expiry-time`, which bounds a normal recovery grant: the
  timer moves it to the trusted window deadline, and the next stick run removes
  recovery lines whose key is no longer on the stick. That is housekeeping, not
  a security boundary: the image is unsigned, so whoever controls the stick
  controls the expiry it writes, and an injected key has passwordless sudo,
  from which permanent access follows. The control is custody of the recovery
  media: hand it to someone you trust and take it back. The durable grant
  belongs on the bastion, whose device register records which key may open
  which port.
- The image is not signed and Secure Boot is off (phase 2), so a stick can be
  replaced by anyone who gets hold of it and a spare. The defence is that the
  device must be physically reachable and the stick kept in trusted hands, not
  cryptography on the stick.
- There is no per-device serial file. The serial is printed on the screen and
  reported, which is enough of an accident guard when one site runs the stick
  on several appliances; it is not an access control.

## Rehearsal

The script, its refusals and the screen text are unit-tested against the
ostree partition layout (`tests/unit/gvpn-recovery.bats`), the support-window
marker and the key re-timing in `tests/unit/support-window.bats`, and the stick
writer's disk and image checks in `tests/unit/recovery-usb.bats`, and the
flashable image's partition, FAT label and files in
`tests/unit/recovery-image.bats`. None of that
boots the image: whether the dracut hooks run as intended under systemd as
PID 1 with `root=tmpfs` is not proven yet. Booting the
real image needs the Linux QEMU
harness (`tools/vm.sh`) with the ESP attached as USB storage and a fresh OVMF
variable store, asserting the green path, each refusal, the idempotent rerun,
and a real `ssh -i <injected key> devops@…` on the installed disk afterwards.
Two things only a real appliance can prove: that its firmware lists the stick
as `UEFI:` and boots `\EFI\BOOT\BOOTX64.EFI`, and that the injected keys log in
over the LAN.
