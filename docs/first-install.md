# First install

Install the OS on a Beelink SER8 or GEEKOM A8 or in an Incus VM from the
unattended installer, provision the node and check it. **The installer wipes its
install disk without asking**: the only internal disk it finds, or the one
`GVPN_INSTALL_DISK` names. Replace every example value below with your
deployment's. For a QEMU rehearsal see
[build.md](build.md#first-install-rehearsal); for the VM specifics see
[incus.md](incus.md); to update installed devices see
[publish-image.md](publish-image.md).

## Choose your setup

A device is set up by two independent choices: how it is managed and what it
runs on. Every combination is a supported setup. They share the image, the
installer, the provisioning and the checks.

Management decides how the device is reached afterwards, and it is decided when
the installer is built:

|                           | Managed                                                                                                 | Unmanaged                                                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Who it is for             | Someone who installs and provisions devices before they go to their site, and administers them remotely | An operator who installs the device they run themselves                                                                |
| How the device is reached | Through a reverse SSH tunnel to a support bastion you operate, and over SSH from its LAN                | Over SSH from its LAN only                                                                                             |
| Needs a bastion           | Yes ([bastion.md](bastion.md))                                                                          | No                                                                                                                     |
| The installer carries     | Your SSH public key and a per-device enrollment private key                                             | Your SSH public key, or no key at all; no secret                                                                       |
| Where the ISO comes from  | A local build per device (`just iso`); never published                                                  | A local build (`just iso` or `just iso-console`), or the ISO CI publishes                                              |
| Steps                     | All of them                                                                                             | Skip step 1, the bastion inputs in step 3 and the bastion parts of steps 4 and 5; read [local access](local-access.md) |

The target decides where the installer runs. The same ISO serves both:

|                        | Hardware                                        | VM                                                                                |
| ---------------------- | ----------------------------------------------- | --------------------------------------------------------------------------------- |
| Machine                | Beelink SER8 or GEEKOM A8                       | Incus VM on a Linux host with KVM, at least 8 vCPUs, 16 GiB RAM and a 64 GiB disk |
| Install disk           | The internal NVMe disk, picked by the installer | The VM's root disk, picked by the installer                                       |
| Firmware and TPM       | UEFI set up by hand (step 2), firmware fTPM     | UEFI and a vTPM, supplied by Incus                                                |
| How the ISO gets there | A USB stick (`just usb`)                        | A disk Incus attaches (`just incus-install`)                                      |
| Console                | Keyboard and monitor (tty1)                     | The VM's serial console (`just incus-console`)                                    |
| Details                | This runbook                                    | This runbook and [Incus VM](incus.md)                                             |

Steps and paragraphs that apply to one value only say so: _Managed only_,
_Unmanaged only_, _Hardware only_ or _VM only_. Everything else applies to every
setup.

An unmanaged device dials nowhere for support: there is no tunnel, no enrollment
key and no support window to manage. The bastion is chosen when the installer is
built, so moving a device from managed to unmanaged or back means installing it
again.

First access is a third property of the installer, independent of the target:

- **Key-configured** (`just iso`): your SSH public key (`GVPN_DEVOPS_SSH_KEY`)
  logs in as `devops`; the `devops` password is locked.
- **Console-configured** (`just iso-console`, and the ISO CI publishes): no SSH
  key. `devops` gets the temporary password `gvpn-exit`, expired, so the first
  console login must change it; then you install your own key
  ([first access on the console](local-access.md#first-access-on-the-console)).

A managed installer is always built key-configured with `just iso`.

## What you need from the HOPR / GnosisVPN side

Three inputs are needed for a working exit. None of them comes from this
repository: the first has a default endpoint, and the third is not automated
here but requested from the Gnosis VPN project through its contact.

1. **A Blokli endpoint URL** for the network the node shall join. `finalize`
   takes it as `--blokli-url` (step 5), which stays required because no URL is
   baked into the image; the default endpoint to pass is
   https://blokli.piz-palu.gnosisvpn.io.
2. **A funded Safe and module for the node address.** You create them with the
   `hopli` release pinned in `image/versions.env` or at hub.hoprnet.org, and you
   fund them; that is step 5.2. The appliance never holds an admin key.
3. **The node address on the GnosisVPN client's destination list.** Without it
   no client uses the exit, however healthy the device looks; step 5 hands the
   address over once provisioning has printed it. This repository does not
   automate the list: request the entry from the Gnosis VPN project through
   support@gnosisvpn.com, the contact address on the project's site
   (https://vpn.gnosis.eth.limo/), which also links the Gnosis Discord
   (https://discord.gg/gnosis).

The client needs no configuration change for a listed exit: it uses the session
targets built into it (`172.30.0.1`).

## 1. Prepare the bastion

_Managed only._

The device dials out to a support bastion you operate, so no inbound router port
or public IP is needed; [bastion.md](bastion.md) describes a minimal one and the
onboarding step by step. For each device, prepare:

- a free reverse port on the bastion's loopback, 1024-65535
  (`GVPN_SUPPORT_PORT`);
- an enrollment key pair whose public key the bastion admits only for that port
  (`permitlisten="localhost:<port>"`, no command execution);
- the bastion's host key in known_hosts form (`GVPN_BASTION_KNOWN_HOSTS`).

The enrollment key provides first access. The support key created during
provisioning (step 5) replaces it.

## 2. Prepare the device

_Hardware only._ A VM needs no firmware setup; Incus supplies UEFI, a vTPM and
the disk. Check the host against the [VM prerequisites](incus.md#prerequisites)
instead.

In the firmware setup:

- AC power loss: power on (Always On)
- Power mode: Performance
- fTPM: enabled (provisioning requires a TPM)
- Secure Boot: off
- Boot from the USB stick once; NVMe first afterwards

Select the stick in the firmware's UEFI boot menu. On the A8 try `F7` for the
boot menu and `Del` for setup; check your model's manual. If the stick is not
listed, connect it directly without a hub and try another port or stick.

## 3. Get the installer

A managed device needs a local build. An unmanaged device takes a local build or
the published ISO. Stop if any step fails.

### Build it locally

Needs Nix, Docker (or root with Podman) and an image-update key pair you hold
(`GVPN_COSIGN_PUB`; `cosign generate-key-pair`); see
[build inputs](build.md#deployment-inputs). A key-configured ISO also needs your
SSH public key, and the managed setup the bastion inputs from step 1. Build
right before installing: every `just iso` and `just iso-console`, including the
QEMU rehearsal's, overwrites the same `output/iso/bootiso/install.iso`.

`GVPN_DEVOPS_SSH_KEY` is the public key that logs in as `devops` on a
key-configured device. It is the only way into the device over the LAN, so use a
key whose private half you keep
([local access](local-access.md#the-key-in-the-installer)).

```sh
nix develop -c just test
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'   # public half of your update key
export GVPN_DEVOPS_SSH_KEY="$HOME/.ssh/id_ed25519.pub"
```

Managed only; leave all four unset for an unmanaged device:

```sh
export GVPN_BASTION='ssh://gvpn-bastion@bastion.example.org:2222'   # or user@host for port 22
export GVPN_SUPPORT_PORT=22001
export GVPN_ENROLL_KEY='/secure/path/enroll.key'
export GVPN_BASTION_KNOWN_HOSTS='/secure/path/bastion_known_hosts'
```

The four bastion inputs come as a set: the build refuses some of them without
the others.

```sh
nix develop -c just iso            # key-configured; just channel=stable iso for stable
nix develop -c just iso-console    # console-configured, no SSH key
```

The installer picks its install disk itself (`GVPN_INSTALL_DISK=auto`, the
default): the only internal disk, ignoring USB and other removable disks and its
own install media. When it finds none or more than one, it stops with an error.
A device with more than one internal disk needs the disk pinned by its kernel
name (`nvme0n1`, `sda`, `vda`):

```sh
GVPN_INSTALL_DISK=nvme0n1 nix develop -c just iso
```

The installer wipes the disk it picked or was given without asking. In the
managed setup **the ISO, and a stick written from it, contain the enrollment
private key**: build one per device and protect both; such an ISO is never
published. An unmanaged ISO carries public keys only, or no key, and can be
reused for every device that shall accept the same SSH key. The installed system
tracks `<GVPN_IMAGE_REPO>:canary` unless built with `channel=stable`.

### Pull the published ISO

_Unmanaged only._

CI builds the installer on every merge to `main` and publishes it as a signed
OCI artifact next to the image, or in the repository `GVPN_ISO_REPO` names when
the operator keeps installers apart, under the immutable tag `iso-<version>`;
the channel tag `iso-canary` moves after the matching image was promoted
([publishing](publish-image.md#publish-the-installer-iso)). It is one ISO for
both targets: unmanaged, console-configured and with the install disk picked at
install time. A device installed from it tracks `<GVPN_IMAGE_REPO>:canary` and
follows that tag wherever it points: there is no minimum-version floor. An
`iso-<version>` that is newer than `canary`, which every merge build is until it
is promoted, installs a device that then updates to the older canary image, a
downgrade. Install the promoted ISO (`canary`, or the version `canary` points
at) unless you mean to test an unpromoted build.

```sh
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'
# export GVPN_ISO_REPO='registry.example.org/fleet/gvpn-exit-os-iso'  # only if the ISO has its own repository
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'
nix develop -c just pull-iso VERSION    # or canary
```

Replace `VERSION` with the version printed by the merge build; use `canary` once
`iso-canary` was moved to it. `pull-iso` downloads with `oras` into
`output/published-iso/`, verifies the signature against `GVPN_COSIGN_PUB` and
the checksums of the ISO, its version and its target, and prints the path of
`install.iso`. A version is checked against the signed version of the artifact;
`canary` is whatever signed ISO the tag points at. The registry must allow
anonymous pulls (as it does for image updates) or accept your registry login.

### Put it on the device

_Hardware only._ Write the stick:

```sh
nix develop -c just usb /dev/sdX                                      # the local build
nix develop -c just usb /dev/sdX output/published-iso/install.iso     # the published ISO
```

**`just usb` destroys the selected disk**: give the whole removable disk, not a
partition, and check it before confirming. It asks for confirmation and `sudo`.

_VM only._ There is no stick. `just incus-install` builds a key-configured ISO
with `just iso` and creates the VM; `just incus-install ISO` installs a given
file, and `just incus-install-published VERSION` pulls the published ISO and
installs it ([creating the VM](incus.md#create-the-vm)).

## 4. Install and connect

_Hardware only._ Connect the 2.5GbE port to a DHCP LAN and boot from the stick.
The installer runs without prompts and reboots; then remove the stick.

_VM only._ The installer runs on the VM console and reboots; leave the console
with `Ctrl-a q` and boot the installed disk with `just incus-run`.

If the installer stops because it found no internal disk or more than one, build
the ISO again with `GVPN_INSTALL_DISK` naming the disk (step 3).

Console-configured ISO only: log in as `devops` with `gvpn-exit` on the console
(keyboard and monitor on hardware, `just incus-console` in a VM), choose a new
password and install your public key
([first access on the console](local-access.md#first-access-on-the-console)).
Then continue over SSH.

Managed only: once the enrollment tunnel is up, connect through the bastion
([reaching a device](bastion.md#reaching-a-device)):

```sh
ssh -J gvpn-bastion@bastion.example.org:2222 -p 22001 devops@127.0.0.1
```

Every setup: on the LAN, find the device's DHCP address in the router; SSH is
accepted from RFC1918 sources only:

```sh
ssh -i ~/.ssh/id_ed25519 devops@DEVICE_IP
```

In a VM, use `just incus-ssh` (it resolves the bridge address) or
`ssh -i ~/.ssh/id_ed25519 devops@VM_BRIDGE_IP`; there is no router lease to
find.

There are no SSH passwords: only `devops` with an installed key can log in over
SSH, and `devops` has passwordless sudo. On a key-configured device a keyboard
and monitor are not a way in. On a console-configured device they are, and so is
the VM console: anyone at it can log in as `devops` with the password chosen at
the first login, or with `gvpn-exit` until then, and has root through `sudo`.
Once your key works, close that with `sudo passwd -l devops`; key login keeps
working. Verify the device's host key through a trusted channel before accepting
it; [local access](local-access.md) covers that, a client configuration and how
to add or replace keys on the device.

`sudo gvpn-exit-status` should report `state: unprovisioned`, the tracked image
and booted digest, firewall and netdata `ok`, Blokli, hoprd and WireGuard
`skipped (unprovisioned)`, and `summary: 0 FAIL`. From the LAN only SSH and ICMP
echo are accepted.

## 5. Provision

```sh
sudo gvpn-exit-provision identity
```

This prints the node address, peer id and support public key;
`sudo gvpn-exit-status` now shows `identity created, not finalized`. Then:

1. Managed only: admit the support key on the bastion with the same restriction
   as the enrollment key. An unmanaged device prints the key as well; nothing
   uses it for access there.
2. From a secure operator environment, create and fund the Safe and module for
   the node address with the matching `hopli` release (see `image/versions.env`)
   or hub.hoprnet.org. Never put an admin key on the appliance.
3. Confirm with `timedatectl` that the clock is NTP-synchronized; on a managed
   device finalize opens the support window and fails otherwise. Then finalize
   with the real addresses (`0x` plus 40 hex digits) and reboot:

```sh
sudo gvpn-exit-provision finalize \
  --safe-address 0x... --module-address 0x... \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io \
  --location "Berlin, DE"
# optional: --peer-rate-kbit N --aggregate-kbit N --peer-max-octet N
#           (rates 1..9999999999 without leading zeros; the set must leave
#            at least one client slot)
#           --fleet-url https://...  (fleet backend: not implemented, part of the roadmap)
# managed:  --support-days N (1-90, default 90)
#           --support-port N --bastion user@host  (default: the installer's)
sudo systemctl reboot   # only after finalize succeeded
```

`finalize` runs once per device. On an unmanaged device it opens no support
window and starts no tunnel; after the reboot, log in from the LAN as before.
`--support-days` is a managed option; on an unmanaged device it opens no tunnel,
but it still requires a synchronized clock and records a deadline that
`gvpn-exit-support status` and the heartbeat report, so leave it out there.

Managed only: `finalize` deletes the enrollment key; the open session survives
until the reboot, and `autossh` reconnects on its own while
`enroll-tunnel.service` keeps running. What `finalize` does end is the ability
to restart that unit. If it stops before the reboot,
`support-tunnel-expire.timer` (every five minutes, gated on the marker
`finalize` wrote) starts the support tunnel with the sealed key instead,
provided you admitted that key in step 5.1 and the reverse port is free. After
the reboot, reconnect through the support tunnel and revoke the enrollment key
on the bastion.

Every setup, after the reboot:

- store the printed provisioning record in your own records; a fleet inventory
  is not implemented, part of the [roadmap](roadmap.md#fleet-and-onboarding);
- hand the node address to the Gnosis VPN project through support@gnosisvpn.com
  so it is added to the client destination list
  ([what you need from the
  HOPR / GnosisVPN side](#what-you-need-from-the-hopr--gnosisvpn-side)). Clients
  need no override; they use the session targets built into them.

## 6. Check

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
  WARN means the probe failed or never ran: either the last good sample still
  applies or, with no sample at all, the device serves one client on the
  fallback capacity
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

The first provisioned boot discovers the public IPv4 once and enables
announcement ([details](architecture.md#reachability)). After moving the device
to its site, or whenever its public IP changes, run:

```sh
sudo gvpn-exit-hoprd-address refresh   # discovers, saves, restarts hoprd
```

Announcement does not make the node reachable: unsolicited inbound 9091 stays
blocked.

netdata, every setup:

```sh
ssh -L 19999:127.0.0.1:19999 devops@DEVICE_IP   # then open http://127.0.0.1:19999
```

The support window, managed only:

```sh
sudo gvpn-exit-support status
sudo gvpn-exit-support extend 7                  # days; requires NTP sync
sudo gvpn-exit-support close                     # LAN SSH keeps working
```

## 7. Acceptance gate

A clean `gvpn-exit-status` on a development network is not acceptance for a
site; it checks none of the following. Install a device only when:

- it is provisioned and funded on the confirmed production network and
  endpoints;
- its node address is on the GnosisVPN client's destination list, requested from
  the Gnosis VPN project through support@gnosisvpn.com;
- a GnosisVPN client session through it succeeded from outside the staging
  network.

Tooling for this gate is [open work](roadmap.md#fleet-and-onboarding).

## 8. Ship a pre-provisioned device

_Managed only, hardware only._

A device that passed steps 1 to 7 on your bench can go to its site as it is:
whoever receives it connects power and the 2.5GbE port to a DHCP LAN and does
nothing else. Before it leaves:

- check that the support window covers shipping and the first weeks on site
  (`sudo gvpn-exit-support status`; `finalize` opened 90 days by default). A
  device whose window ran out is reachable from its LAN or with the
  [recovery stick](recovery.md) only;
- make sure the support key and the operator keys for its port are admitted on
  the bastion ([bastion.md](bastion.md#onboarding-one-device)).

Once it is online at the site, connect through the bastion and run
`sudo gvpn-exit-hoprd-address refresh`, because the public address changed with
the move, then repeat step 6. Extend the window before it expires for as long as
you administer the device remotely.

The person on site has no login unless you add their key
([local access](local-access.md#adding-and-replacing-keys)); the device needs
none to run.
