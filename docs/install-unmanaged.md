# Install an unmanaged device

An unmanaged device is installed by the operator who runs it and is reached over
SSH from its LAN only. It needs no support bastion: it dials nowhere for
support, so it has no tunnel, no enrollment key and no support window, and its
installer carries no secret. If you prepare devices on a bench and administer
them remotely after they have gone to their sites, follow
[Install a managed device](install-managed.md) instead
([which setup fits](install.md#choose-your-setup)).

The guide covers hardware (any machine that meets the
[hardware requirements](install.md#hardware-requirements)) and Incus VMs; steps
marked _Hardware only_ or _VM only_ apply to that target alone, and
[Incus VM](incus.md) collects what the VM changes. Replace every example value
with your deployment's.

**The installer wipes its install disk without asking**: the only internal disk
it finds, or the one `GVPN_INSTALL_DISK` names. The unmanaged setup is fixed
when the installer is built; turning the device into a managed one later means
installing it again.

## Before you start

- A laptop or workstation on the LAN the device will sit on, with an OpenSSH
  client. The device accepts SSH only from private (RFC1918) source addresses on
  its wired port, and port forwarding on the router does not change that
  ([local access](local-access.md)). To work on it from elsewhere later you need
  your own way into that network, such as a VPN or a host on it to jump through.
- An SSH key pair on that laptop whose private half you keep; its public half
  becomes the key that logs in as `gvpn`. Create one with
  `ssh-keygen -t ed25519 -f ~/.ssh/gvpn-exit` if you have none; a key-configured
  local build needs it before step 2, the console-configured path creates it in
  step 5.
- The inputs from the HOPR / GnosisVPN side: a Blokli URL, a way to create and
  fund a Safe and module, and a contact to list the node address
  ([what you need](install.md#what-you-need-from-the-hopr--gnosisvpn-side)).
- _Hardware only:_ a machine that meets the
  [hardware requirements](install.md#hardware-requirements), a USB stick, and a
  keyboard and monitor if the installer is console-configured (the published
  ISO, or `just iso-console`).
- _VM only:_ a host that meets the [VM prerequisites](incus.md#prerequisites).

## 1. Prepare the device

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

## 2. Get the installer

Two sources serve an unmanaged device. Pick one before you go on:

|                       | Published ISO                                                    | Local build                                                                            |
| --------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| What you need         | `curl`, `jq`, `openssl` and `sha256sum`, or this repository      | A Linux workstation with Nix and Docker (or root with Podman), and your own update key |
| Who signs the updates | The publisher of the ISO repository; the device trusts their key | You; the device trusts the public half of the key you build with                       |
| First access          | Console only: no SSH key, temporary `gvpn` password              | Your SSH key (`just iso`), or the console (`just iso-console`)                         |
| Install disk          | Picked at install time                                           | Picked at install time, or pinned with `GVPN_INSTALL_DISK`                             |

A device follows one update channel of one image repository and accepts only
images signed by the key its installer was built with. No runbook moves an
installed device to images signed by another key; install it again for that.
Take the published ISO when you run the publisher's releases; build locally when
you publish your own images ([publishing](publish-image.md)) or need the install
disk pinned.

### Pull the published ISO

The GnosisVPN project publishes its installer in
`europe-west3-docker.pkg.dev/gnosisvpn-production/iso-images/gnosis-vpn-exit-os`;
install the ISO under its `stable` tag. A device installed from it follows
`europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis-vpn-exit-os:stable`
for its updates and accepts only images signed with the GnosisVPN image-update
key. Save the public half of that key on the machine that pulls the ISO; both
ways of pulling below verify the ISO against it:

```sh
cat > gnosisvpn-cosign.pub <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmD2CqOQvacCaaSxQZskffjsZgQ3P
QoheEHjrWfYVi+BdGYobwq1jbKshqGkLzLskmMk9FJyvI71Xoprskp2P1g==
-----END PUBLIC KEY-----
EOF
```

To install the ISO of another publisher, use their repository and their public
key instead of these two.

Every promotion of an image version to a channel builds the installer of that
channel and publishes it as a signed OCI artifact in a repository of its own
(`GVPN_ISO_REPO`), under the immutable `<version>-<channel>` tag and the moving
`<channel>` tag ([publishing](publish-image.md#publish-the-installer-iso)). It
is one ISO for both targets: unmanaged, console-configured and with the install
disk picked at install time. A device installed from it trusts images signed
with the image-update key and follows the channel of its ISO for its updates:
the ISO under `stable` installs a device that tracks `<GVPN_IMAGE_REPO>:stable`,
the ISO under `canary` one that tracks `<GVPN_IMAGE_REPO>:canary`.

`stable` is the soaked release; `canary` gets every promoted build first; each
exists once a version was promoted to it. A `VERSION-CHANNEL`, as printed by the
promotion, names one ISO. The device follows its channel tag wherever it points:
there is no minimum-version floor, so an ISO of a version newer than its channel
now points at installs a device that then updates to the older image, a
downgrade. Install the ISO a channel tag points at unless you mean otherwise.

With this repository, on any machine with Nix:

```sh
export GVPN_ISO_REPO='europe-west3-docker.pkg.dev/gnosisvpn-production/iso-images/gnosis-vpn-exit-os'
export GVPN_COSIGN_PUB="$PWD/gnosisvpn-cosign.pub"
nix develop -c just pull-iso stable    # or canary, or VERSION-CHANNEL
```

`pull-iso` downloads with `oras` into `output/published-iso/`, verifies the
signature against `GVPN_COSIGN_PUB` and the checksums of the ISO, its version
and its target, and prints the path of `install.iso`. The channel is checked
against the signed channel of the artifact, and a `VERSION-CHANNEL` also against
its signed version; under a channel tag the version is whatever signed ISO of
that channel the tag points at. The GnosisVPN registry serves anonymous pulls;
the registry of another publisher must do the same (as it does for image
updates) or accept your registry login.

Without this repository or `oras`, `curl`, `jq`, `openssl` and `sha256sum` do
the same. Each file of the artifact is a layer named after it. The signature in
`install.iso.sha256.sigstore.json` is a plain ECDSA signature of
`install.iso.sha256`, so `openssl` verifies it against the public key; the
signed checksum file then covers the ISO and both sidecars. The registry has to
serve anonymous pulls without a token, as Google Artifact Registry does for a
public repository.

```sh
REPO='europe-west3-docker.pkg.dev/gnosisvpn-production/iso-images/gnosis-vpn-exit-os'
TAG='stable'    # or canary, or VERSION-CHANNEL
H="https://${REPO%%/*}" N="${REPO#*/}"
curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "${H}/v2/${N}/manifests/${TAG}" > manifest.json
for f in install.iso install.iso.sha256 install.iso.sha256.sigstore.json \
         install.iso.version install.iso.target; do
  digest="$(jq -er --arg f "${f}" \
    '.layers[] | select(.annotations["org.opencontainers.image.title"] == $f) | .digest' manifest.json)"
  curl -fsSL -o "${f}" "${H}/v2/${N}/blobs/${digest}"
done

# the signature on the checksum file, against the image-update public key
jq -r .messageSignature.signature install.iso.sha256.sigstore.json | base64 -d > install.iso.sha256.sig
openssl dgst -sha256 -verify gnosisvpn-cosign.pub -signature install.iso.sha256.sig install.iso.sha256
# the signed list names exactly the ISO and both sidecars, and they match it
awk '{ print $2 }' install.iso.sha256 | sort | paste -sd' '   # install.iso install.iso.target install.iso.version
sha256sum -c --strict install.iso.sha256
# what the signed sidecars say: the version, and disk=auto, enrollment=none,
# access=console and the channel the device follows (channel=, the one in TAG)
cat install.iso.version install.iso.target
```

`openssl` must print `Verified OK`. Check the last three outputs by eye:
`just pull-iso` refuses an ISO whose list or target differs, and a version or
channel that is not the one asked for. Stop if any check fails.

### Build it locally

On a Linux build workstation with Nix and Docker (or root with Podman), with an
image-update key pair you hold (`cosign generate-key-pair`;
[deployment inputs](build.md#deployment-inputs)). Build right before installing:
every `just iso` and `just iso-console`, including the QEMU rehearsal's,
overwrites the same `output/iso/bootiso/install.iso`.

```sh
nix develop -c just test
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'   # public half of your update key
export GVPN_OPERATOR_SSH_KEY="$HOME/.ssh/id_ed25519.pub"
nix develop -c just iso            # key-configured; just channel=stable iso for stable
nix develop -c just iso-console    # or: console-configured, no SSH key
```

Leave `GVPN_BASTION`, `GVPN_SUPPORT_PORT`, `GVPN_ENROLL_KEY` and
`GVPN_BASTION_KNOWN_HOSTS` unset: with them the build produces a managed
installer. `GVPN_OPERATOR_SSH_KEY` is the only way into a key-configured device
over the LAN, so use a key whose private half you keep; `just iso-console` does
not read it. The installed system tracks `<GVPN_IMAGE_REPO>:canary` unless built
with `channel=stable`.

The installer picks its install disk itself (`GVPN_INSTALL_DISK=auto`, the
default): the only internal disk, ignoring USB and other removable disks and its
own install media. When it finds none or more than one, it stops with an error.
A device with more than one internal disk needs the disk pinned by its kernel
name (`nvme0n1`, `sda`, `vda`):

```sh
GVPN_INSTALL_DISK=nvme0n1 nix develop -c just iso
```

An unmanaged ISO carries public keys only, or no key, and can be reused for
every device that shall accept the same SSH key.

## 3. Put the installer on the device

_Hardware only._ Write the stick:

```sh
nix develop -c just usb /dev/sdX                                      # the local build
nix develop -c just usb /dev/sdX output/published-iso/install.iso     # the published ISO
```

**`just usb` destroys the selected disk**: give the whole removable disk, not a
partition, and check it before confirming. It asks for confirmation and `sudo`.

_VM only._ There is no stick. On the Incus host
([creating the VM](incus.md#create-the-vm)):

```sh
nix develop -c just incus-install-published stable   # pulls and verifies the published ISO (GVPN_ISO_REPO, GVPN_COSIGN_PUB as above)
nix develop -c just incus-install ISO                # an ISO you built or pulled
nix develop -c just incus-install                    # builds a key-configured ISO first
```

## 4. Install

_Hardware only._ Connect the wired Ethernet port to a DHCP LAN, then boot from
the stick through the firmware's UEFI boot menu. If the stick is not listed,
connect it directly without a hub and try another port or stick. The installer
runs without prompts and powers the device off when it is done. Remove the
stick, then power the device on again.

_VM only._ The installer runs on the VM console and powers the VM off when it is
done, which ends the console; boot the installed disk with `just incus-run`.

If the installer stops because it found no internal disk or more than one, build
the ISO again with `GVPN_INSTALL_DISK` naming the disk
([build it locally](#build-it-locally)); the published ISO cannot pin a disk.

## 5. First login

The device accepts SSH as `gvpn` only, from private (RFC1918) addresses on its
LAN, and `gvpn` has passwordless `sudo`. How you log in the first time depends
on the installer: a console-configured one (the published ISO, or
`just iso-console`) installs no SSH key, a key-configured one (`just iso`)
installs yours. Follow the matching subsection; both end at
[check before provisioning](#check-before-provisioning).

"Laptop" below is the machine you will administer the device from. It needs an
OpenSSH client (`ssh`, `ssh-keygen`, `ssh-copy-id`) and must be on the device's
LAN; for a VM it is the Incus host, whose bridge address is private.

### With a console-configured installer

The image allows SSH logins with a key only, and this device has no key yet. You
therefore set a password on the console, allow SSH passwords for the few minutes
it takes to copy your key over, and then turn password login off again.

**While password login is on, anyone on the device's LAN who has the `gvpn`
password gets root on the device.** Choose a strong password in step 1 and
finish step 7 in the same sitting.

1. **On the device's console** (keyboard and monitor on hardware,
   `just incus-console` in a VM, where you press Enter to see the prompt), log
   in as `gvpn` with the temporary password `exit4gvpn`. It has expired, so the
   login asks for the current password once more and then for a new one, twice.
   From now on the console accepts only the new password.

2. **On the device's console**, read the device's LAN address and its SSH host
   key fingerprint, and write both down:

   ```sh
   ip -4 -br addr show lan0                            # lan0  UP  192.168.1.23/24
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub    # SHA256:... (ED25519)
   ```

   The address is the part before the slash, `DEVICE_IP` below. The router's
   DHCP lease table lists the same address under the name `gvpn-exit`; give the
   device a fixed lease there so the address stays the same.

3. **On the device's console**, allow password login over SSH:

   ```sh
   echo 'PasswordAuthentication yes' | sudo tee /etc/ssh/sshd_config.d/30-gvpn-first-access.conf
   sudo systemctl reload sshd
   sudo sshd -T | grep -i '^passwordauthentication'    # passwordauthentication yes
   ```

   sshd reads the files in `/etc/ssh/sshd_config.d/` in name order and keeps the
   first value it finds, so `30-...` overrides the image's `40-gvpn-exit.conf`.
   The file stays in `/etc` across reboots and updates until you delete it in
   step 7.

4. **On the laptop**, create a key pair, unless you already have one you want to
   use. Give it a passphrase; the private half never leaves the laptop:

   ```sh
   ssh-keygen -t ed25519 -f ~/.ssh/gvpn-exit -C "you@laptop"
   ```

5. **On the laptop**, log in with the new password:

   ```sh
   ssh -o PubkeyAuthentication=no gvpn@DEVICE_IP
   ```

   SSH shows the device's host key fingerprint and asks whether to trust it.
   Answer `yes` only if it matches the fingerprint from step 2. Then enter the
   password from step 1. You are on the device; leave with `exit`.
   `PubkeyAuthentication=no` keeps the client from offering every key it has
   first, which can use up the server's login attempts before the password
   prompt appears.

6. **On the laptop**, copy the public key to the device; it asks for the
   password once more:

   ```sh
   ssh-copy-id -i ~/.ssh/gvpn-exit.pub gvpn@DEVICE_IP
   ```

   Without `ssh-copy-id`, this does the same:

   ```sh
   ssh -o PubkeyAuthentication=no gvpn@DEVICE_IP 'install -d -m 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < ~/.ssh/gvpn-exit.pub
   ```

   Then log in with the key, and keep this session open:

   ```sh
   ssh -i ~/.ssh/gvpn-exit -o PasswordAuthentication=no gvpn@DEVICE_IP
   ```

   It must log you in without asking for the device password (the key's own
   passphrase is asked by the laptop). If it does not, stay on the console, do
   not go on to step 7, and check `~/.ssh/authorized_keys` on the device: owned
   by `gvpn`, mode `0600`, one key per line.

7. **On the device, in the key session from step 6**, turn password login off
   again and lock the `gvpn` password:

   ```sh
   sudo rm /etc/ssh/sshd_config.d/30-gvpn-first-access.conf
   sudo systemctl reload sshd
   sudo sshd -T | grep -i '^passwordauthentication'    # passwordauthentication no
   sudo passwd -l gvpn
   ```

   Locking the password closes the console as well: until then anyone at the
   keyboard and monitor, or with access to the VM console, can log in with it
   and has root through `sudo`. Key login over SSH keeps working. Without a
   working key afterwards, the way back in is the [recovery stick](recovery.md).

   **On the laptop**, in a second terminal, check that SSH refuses passwords
   now:

   ```sh
   ssh -o PubkeyAuthentication=no gvpn@DEVICE_IP      # Permission denied (publickey).
   ```

An entry in `~/.ssh/config` on the laptop saves the options from now on
([first login](local-access.md#first-login)).

### With a key-configured installer

The installer put `GVPN_OPERATOR_SSH_KEY` into `gvpn`'s `authorized_keys` and
locked the `gvpn` password, so SSH with that key is the only way in; a keyboard
and monitor are not. Find the device's address **on the laptop**: the router's
DHCP lease table lists it as `gvpn-exit`, or scan your LAN for SSH (replace the
range with your LAN's; `nmap` is not installed everywhere):

```sh
nmap -p 22 --open 192.168.1.0/24
```

In a VM, `just incus-ssh` finds the bridge address itself, and
`incus list gvpn-exit` shows it.

Then log in **from the laptop** with the private half of that key:

```sh
ssh -i ~/.ssh/id_ed25519 gvpn@DEVICE_IP
```

Nothing shows the host key fingerprint beforehand, so make this first connection
on a network you trust, such as your own LAN right after the install, and record
the fingerprint ([first login](local-access.md#first-login)).

### Check before provisioning

On the device, `sudo gvpn-exit-status` should report `state: unprovisioned`, the
tracked image and booted digest, firewall and netdata `ok`, Blokli, hoprd and
WireGuard `skipped (unprovisioned)`, and `summary: 0 FAIL`.

## 6. Provision the node

On the device:

```sh
sudo gvpn-exit-provision identity
```

This prints the node address (in EIP-55 checksum form, as every address the
operator tools print), peer id and a support public key, which nothing uses for
access on an unmanaged device. `sudo gvpn-exit-status` now shows
`identity created, not finalized`. Then:

1. From a secure operator environment, create and fund the Safe and module for
   the node address with the matching `hopli` release (see `image/versions.env`)
   or hub.hoprnet.org. Never put an admin key on the appliance.
2. On the device, finalize with the real addresses (`0x` plus 40 hex digits) and
   reboot:

```sh
sudo gvpn-exit-provision finalize \
  --safe-address 0x... --module-address 0x... \
  --blokli-url https://blokli.piz-palu.gnosisvpn.io \
  --location "Berlin, DE"
# optional: --peer-rate-kbit N --aggregate-kbit N --peer-max-octet N
#           (rates 1..9999999999 without leading zeros; the set must leave
#            at least one client slot)
#           --fleet-url https://...  (fleet backend: not implemented, part of the roadmap)
sudo systemctl reboot   # only after finalize succeeded
```

`finalize` runs once per device; a second run is refused. On an unmanaged device
it opens no support window and starts no tunnel. Leave out `--support-days`: it
opens no tunnel here, but it still requires a synchronized clock and records a
deadline that `gvpn-exit-support status` and the heartbeat report.

After the reboot:

- log in from the LAN as before;
- store the printed provisioning record in your own records;
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

netdata listens on the device's loopback; forward it over SSH:

```sh
ssh -L 19999:127.0.0.1:19999 gvpn@DEVICE_IP   # then open http://127.0.0.1:19999
```

A green `gvpn-exit-status` does not show that clients can use the exit: check
the device against the [acceptance gate](install.md#acceptance-gate).

## 8. Keep the public address current

The first provisioned boot discovers the public IPv4 once and enables
announcement ([details](architecture.md#reachability)). After moving the device
to another site, or whenever its public IP changes, run on the device:

```sh
sudo gvpn-exit-hoprd-address refresh   # discovers, saves, restarts hoprd
```

Announcement does not make the node reachable: unsolicited inbound 9091 stays
blocked.

From here on, [local access](local-access.md) covers logging in, adding and
replacing keys, and the [recovery stick](recovery.md) is the way back in when no
key works any more.
