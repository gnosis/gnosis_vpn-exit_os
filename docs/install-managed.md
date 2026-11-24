# Install a managed device

A managed device is prepared on your bench and administered remotely after it
has gone to its site. It keeps a reverse SSH tunnel open to a support bastion
you operate, so you reach its SSH server through the bastion while the site
needs no inbound router port and no public IP. Its installer carries a
per-device enrollment key that opens the first tunnel; provisioning replaces
that key with a support key sealed in the device's TPM. If you install a device
you run yourself and reach from its LAN only, follow
[Install an unmanaged device](install-unmanaged.md) instead
([which setup fits](install.md#choose-your-setup)).

The guide covers hardware (any machine that meets the
[hardware requirements](install.md#hardware-requirements)) and Incus VMs; steps
marked _Hardware only_ or _VM only_ apply to that target alone, and
[Incus VM](incus.md) collects what the VM changes. Replace every example value
with your deployment's.

**The installer wipes its install disk without asking**: the only internal disk
it finds, or the one `GVPN_INSTALL_DISK` names. The managed setup is fixed when
the installer is built; turning the device into an unmanaged one later means
installing it again.

## Before you start

- A bastion you operate, reachable from the device's site and from your
  workstation ([bastion.md](bastion.md)).
- A Linux build workstation with Nix and Docker (or root with Podman), and an
  image-update key pair you hold: its public half (`GVPN_COSIGN_PUB`) goes into
  the image, and its private half signs every update the device will accept
  ([deployment inputs](build.md#deployment-inputs)).
- An SSH key pair whose private half you keep; its public half logs in as `gvpn`
  ([the key in the installer](local-access.md#the-key-in-the-installer)).
- The inputs from the HOPR / GnosisVPN side: a Blokli URL, a way to create and
  fund a Safe and module, and a contact to list the node address
  ([what you need](install.md#what-you-need-from-the-hopr--gnosisvpn-side)).
- _Hardware only:_ a machine that meets the
  [hardware requirements](install.md#hardware-requirements), a USB stick and a
  DHCP LAN for the bench.
- _VM only:_ a host that meets the [VM prerequisites](incus.md#prerequisites).

## 1. Prepare the bastion

On the bastion, for each device
([onboarding one device](bastion.md#onboarding-one-device) has the commands):

- pick a free reverse port on the bastion's loopback, 1024-65535
  (`GVPN_SUPPORT_PORT`);
- generate an enrollment key pair and admit its public key only for that port
  (`permitlisten="localhost:<port>"`, no command execution);
- admit the operator keys that will reach this device;
- write the bastion's host key in known_hosts form (`GVPN_BASTION_KNOWN_HOSTS`).

The enrollment key provides first access. The support key created during
provisioning (step 6) replaces it.

## 2. Prepare the device

_Hardware only._ A VM needs no firmware setup; Incus supplies UEFI, a vTPM and
the disk.

In the firmware setup (names differ between vendors):

- Power restore after AC loss: power on (often called Always On)
- Power or performance mode, where the firmware offers one: Performance
- TPM 2.0 (firmware TPM, often called fTPM or PTT, or a discrete chip): enabled;
  provisioning requires it
- Secure Boot: off
- Boot from the USB stick once; the internal disk first afterwards

The keys for the boot menu and the setup differ between vendors (often `F7`,
`F11`, `F12`, `Esc` or `Del`); check the machine's manual.

## 3. Build the installer

On the build workstation. Build right before installing: every `just iso` and
`just iso-console`, including the QEMU rehearsal's, overwrites the same
`output/iso/bootiso/install.iso`.

```sh
nix develop -c just test
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'   # public half of your update key
export GVPN_OPERATOR_SSH_KEY="$HOME/.ssh/id_ed25519.pub"
export GVPN_BASTION='ssh://gvpn-bastion@bastion.example.org:2222'   # or user@host for port 22
export GVPN_SUPPORT_PORT=22001
export GVPN_ENROLL_KEY='/secure/path/enroll.key'
export GVPN_BASTION_KNOWN_HOSTS='/secure/path/bastion_known_hosts'
nix develop -c just iso            # just channel=stable iso for stable
```

The four bastion inputs come as a set: the build refuses some of them without
the others, and without all four it builds an unmanaged installer. The installed
system tracks `<GVPN_IMAGE_REPO>:canary` unless built with `channel=stable`.

The installer picks its install disk itself (`GVPN_INSTALL_DISK=auto`, the
default): the only internal disk, ignoring USB and other removable disks and its
own install media. When it finds none or more than one, it stops with an error.
A device with more than one internal disk needs the disk pinned by its kernel
name (`nvme0n1`, `sda`, `vda`):

```sh
GVPN_INSTALL_DISK=nvme0n1 nix develop -c just iso
```

**The ISO, and a stick written from it, contain the enrollment private key**:
build one per device and protect both; such an ISO is never published.

## 4. Put the installer on the device

_Hardware only._ Write the stick on the build workstation:

```sh
nix develop -c just usb /dev/sdX
```

**`just usb` destroys the selected disk**: give the whole removable disk, not a
partition, and check it before confirming. It asks for confirmation and `sudo`.

_VM only._ There is no stick. On the Incus host, with the inputs of step 3 still
exported, `just incus-install` builds the installer with `just iso` and creates
the VM; `just incus-install output/iso/bootiso/install.iso` installs the ISO you
already built ([creating the VM](incus.md#create-the-vm)).

## 5. Install and connect

_Hardware only._ Connect the wired Ethernet port to a DHCP LAN, then boot from
the stick through the firmware's UEFI boot menu. If the stick is not listed,
connect it directly without a hub and try another port or stick. The installer
runs without prompts and powers the device off when it is done. Remove the
stick, then power the device on again.

_VM only._ The installer runs on the VM console and powers the VM off when it is
done, which ends the console; boot the installed disk with `just incus-run`.

If the installer stops because it found no internal disk or more than one, build
the ISO again with `GVPN_INSTALL_DISK` naming the disk (step 3).

At its first boot the device opens the enrollment tunnel. From your workstation,
connect through the bastion ([reaching a device](bastion.md#reaching-a-device)):

```sh
ssh -J gvpn-bastion@bastion.example.org:2222 -p 22001 gvpn@127.0.0.1
```

From the device's LAN you can also log in directly. Find its DHCP address in the
router, which lists it as `gvpn-exit`; SSH is accepted from RFC1918 sources
only. In a VM, use `just incus-ssh` (it resolves the bridge address) or the
bridge address instead; there is no router lease to find.

```sh
ssh -i ~/.ssh/id_ed25519 gvpn@DEVICE_IP
```

There are no SSH passwords: only `gvpn` with an installed key can log in, and
`gvpn` has passwordless sudo. The `gvpn` password is locked, so a keyboard and
monitor are not a way in. Verify the device's host key through a trusted channel
before accepting it ([first login](local-access.md#first-login)).

On the device, `sudo gvpn-exit-status` should report `state: unprovisioned`, the
tracked image and booted digest, firewall and netdata `ok`, Blokli, hoprd and
WireGuard `skipped (unprovisioned)`, and `summary: 0 FAIL`.

## 6. Provision the node

On the device:

```sh
sudo gvpn-exit-provision identity
```

This prints the node address (in EIP-55 checksum form, as every address the
operator tools print), peer id and support public key; `sudo gvpn-exit-status`
now shows `identity created, not finalized`. Then:

1. On the bastion, admit the support key with the same restriction and port as
   the enrollment key.
2. From a secure operator environment, create and fund the Safe and module for
   the node address with the matching `hopli` release (see `image/versions.env`)
   or hub.hoprnet.org. Never put an admin key on the appliance.
3. On the device, confirm with `timedatectl` that the clock is NTP-synchronized:
   `finalize` opens the support window and fails without a synchronized clock.
   Then finalize with the real addresses (`0x` plus 40 hex digits) and reboot:

```sh
sudo gvpn-exit-provision finalize \
  --safe-address 0x... --module-address 0x... \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io \
  --location "Berlin, DE"
# optional: --support-days N (1-90, default 90)
#           --support-port N --bastion user@host  (default: the installer's)
#           --peer-rate-kbit N --aggregate-kbit N --peer-max-octet N
#           (rates 1..9999999999 without leading zeros; the set must leave
#            at least one client slot)
#           --fleet-url https://...  (fleet backend: not implemented, part of the roadmap)
sudo systemctl reboot   # only after finalize succeeded
```

`finalize` runs once per device; a second run is refused. It deletes the
enrollment key. The open session survives until the reboot, and `autossh`
reconnects on its own while `enroll-tunnel.service` keeps running; what
`finalize` ends is the ability to restart that unit. If it stops before the
reboot, `support-tunnel-expire.timer` (every five minutes, gated on the marker
`finalize` wrote) starts the support tunnel with the sealed key instead,
provided you admitted that key in step 6.1 and the reverse port is free.

After the reboot:

- reconnect through the bastion as in step 5; the support tunnel now carries the
  session;
- revoke the enrollment key on the bastion;
- store the printed provisioning record in your own records; a fleet inventory
  is not implemented, part of the [roadmap](roadmap.md#fleet-and-onboarding);
- hand the node address to the Gnosis VPN project through support@gnosisvpn.com
  so it is added to the client destination list. Clients need no override; they
  use the session targets built into them.

## 7. Check the device

On the device:

```sh
sudo gvpn-exit-status
```

Expect exit status 0 and:

- `state: provisioned at ...` and the provisioning record
- Blokli `configured` and `used` showing the same URL, `reachable: ok`
- every unit `ok`; FORWARD and INPUT isolation, client tunnel ping and IPv6
  policies `ok`; blocklist with >= 1000 entries
- hoprd health `ok` once funded; an unfunded node keeps its API closed (WARN)
- `wggvpn: ok (listening on 51820)`, shaping `ok` on `wggvpn` and `ifb-gvpn`
- capacity `ok` with the measured uplink, the peer slots and the aggregate; a
  WARN means the probe failed, was rate limited by the speed test endpoint or
  never ran: either the last good sample still applies or, with no sample at
  all, the device serves one client on the fallback capacity; the journal of
  `gvpn-exit-capacity.service` says why
- an announced address matching the observed one, or none if discovery failed
- CPU `governor: ok (performance on N policies)`, energy preference
  `performance` (a VM often exposes no cpufreq policy and reports `n/a`)

Probes behind a FAIL or WARN:

```sh
systemctl status hoprd gnosisvpn-server
journalctl -u hoprd -f
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/healthyz
sudo wg show wggvpn
sudo iptables -S FORWARD          # a GVPN_PRIVATE jump comes first
journalctl -b -u greenboot-healthcheck
journalctl -u gvpn-exit-hoprd-address.service
sudo systemctl start gvpn-exit-netprobe.service
cat /var/lib/gvpn-exit/state/reachability.json
```

The support window, which bounds how long the tunnel runs:

```sh
sudo gvpn-exit-support status
sudo gvpn-exit-support extend 7                  # days; requires NTP sync
sudo gvpn-exit-support close                     # LAN SSH keeps working
```

netdata listens on the device's loopback; forward it over SSH, for example from
the LAN:

```sh
ssh -L 19999:127.0.0.1:19999 gvpn@DEVICE_IP   # then open http://127.0.0.1:19999
```

The first provisioned boot discovers the public IPv4 once and enables
announcement ([details](architecture.md#reachability)). Announcement does not
make the node reachable: unsolicited inbound 9091 stays blocked.

## 8. Ship the device to its site

_Hardware only._ A VM stays where its host is; for it, step 7 ends the
installation.

A green `gvpn-exit-status` on the bench is not acceptance for a site: check the
device against the [acceptance gate](install.md#acceptance-gate) before it goes.
Whoever receives it connects power and the wired Ethernet port to a DHCP LAN and
does nothing else. Before it leaves:

- check that the support window covers shipping and the first weeks on site
  (`sudo gvpn-exit-support status`; `finalize` opened 90 days by default). A
  device whose window ran out is reachable only from its LAN or with the
  [recovery stick](recovery.md);
- make sure the support key and the operator keys for its port are admitted on
  the bastion ([bastion.md](bastion.md#onboarding-one-device)).

Once it is online at the site, connect through the bastion and run:

```sh
sudo gvpn-exit-hoprd-address refresh   # discovers, saves, restarts hoprd
```

because the public address changed with the move; then repeat step 7. Run it
again whenever the site's public IP changes. When the site is not the location
you gave `finalize`, record the new one with
`sudo gvpn-exit-provision location "City, CC"`. Extend the window before it
expires for as long as you administer the device remotely.

The person on site has no login unless you add their key
([local access](local-access.md#adding-and-replacing-keys)); the device needs
none to run.
