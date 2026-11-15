# Install a device

Installing a device turns an x86_64 machine or an Incus VM into a GnosisVPN
exit: an unattended installer writes the OS to the device's disk, you log in
over SSH, provision the node identity and its on-chain Safe, and check the
result. This page helps you pick the guide that fits your device and holds what
every installation needs from outside this repository. The guides are:

- [Install a managed device](install-managed.md)
- [Install an unmanaged device](install-unmanaged.md)

## Choose your setup

Two choices describe a device. They are independent, every combination is
supported, and all of them run the same image, provisioning and checks.

**Management** decides how you reach the device after it is installed. It is
fixed when the installer is built, so moving a device from one setup to the
other means installing it again.

|                       | Managed                                                                                          | Unmanaged                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Who it is for         | Someone who prepares devices on a bench, ships them to their sites and administers them remotely | An operator who installs and runs the device themselves                          |
| How you reach it      | A reverse SSH tunnel to a support bastion you operate, and SSH from its LAN                      | SSH from its LAN only                                                            |
| Needs a bastion       | Yes ([bastion.md](bastion.md))                                                                   | No                                                                               |
| The installer carries | Your SSH public key and a per-device enrollment private key                                      | Your SSH public key, or no key at all; no secret                                 |
| Where the ISO is from | A local build per device (`just iso`); never published                                           | The ISO a promotion publishes, or a local build (`just iso`, `just iso-console`) |
| Guide                 | [install-managed.md](install-managed.md)                                                         | [install-unmanaged.md](install-unmanaged.md)                                     |

A managed device dials out to the bastion, so its site needs no inbound router
port or public IP. An unmanaged device dials nowhere for support: it has no
tunnel, no enrollment key and no support window, and from outside its LAN you
reach it only through your own way into that network
([local access](local-access.md)).

**Target** decides where the installer runs. The same ISO serves both.

|                        | Hardware                                                                         | Incus VM                                                                          |
| ---------------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Machine                | An x86_64 machine that meets the [hardware requirements](#hardware-requirements) | Incus VM on a Linux host with KVM: at least 8 vCPUs, 16 GiB RAM and a 64 GiB disk |
| Firmware and TPM       | UEFI set up by hand, a firmware or discrete TPM 2.0                              | UEFI and a vTPM, supplied by Incus                                                |
| How the ISO gets there | A USB stick (`just usb`)                                                         | A disk Incus attaches (`just incus-install`)                                      |
| Console                | Keyboard and monitor (tty1)                                                      | The VM's serial console (`just incus-console`)                                    |

Both guides cover both targets and mark the steps that apply to one of them
only. [Incus VM](incus.md) collects what the VM changes. A VM is a production
host, not only a test harness, as long as it keeps the resources above.

**First access** is a property of the installer: how you log in for the first
time.

- **Key-configured** (`just iso`): your SSH public key (`GVPN_OPERATOR_SSH_KEY`)
  logs in as `gvpn` over SSH, and the `gvpn` password is locked. A managed
  installer is always key-configured.
- **Console-configured** (`just iso-console`, and the published ISO): no SSH
  key. `gvpn` gets the temporary password `exit4gvpn`, already expired, so the
  first console login must change it; then you install your own key
  ([first access on the console](local-access.md#first-access-on-the-console)).

## Hardware requirements

The installer is generic: it checks for no vendor or model, only for a disk it
can install to. A machine, physical or virtual, needs:

- an x86_64 CPU with at least 8 cores, and at least 16 GiB RAM;
- UEFI boot with Secure Boot off (the installer is not signed);
- a TPM 2.0, firmware or discrete, which provisioning seals the node's
  credentials into;
- exactly one internal disk, which the installer picks and wipes; the Incus VM
  default is 64 GiB. A machine with more than one internal disk needs the disk
  named when the installer is built (`GVPN_INSTALL_DISK`), and the published ISO
  cannot do that;
- exactly one wired Ethernet NIC, ideally 1 Gbit/s or faster, on a DHCP LAN with
  IPv4. Wi-Fi is not supported, and with a second wired NIC which one carries
  the LAN is undefined.

The uplink behind that LAN, the outbound connections the device needs and the
networks it cannot share are in the
[supported environment](architecture.md#supported-environment).

## What you need from the HOPR / GnosisVPN side

A working exit needs three inputs that do not come from this repository.

1. **A Blokli endpoint URL** for the network the node joins. Provisioning takes
   it as `--blokli-url`, which is required because no URL is baked into the
   image. The default endpoint is https://blokli.piz-palu.gnosisvpn.io.
2. **A funded Safe and module for the node address.** You create them after the
   device has printed its node address, with the `hopli` release pinned in
   `image/versions.env` or at hub.hoprnet.org, and you fund them. The appliance
   never holds an admin key.
3. **The node address on the GnosisVPN client's destination list.** Without it
   no client uses the exit, however healthy the device looks. This repository
   does not automate the list: once provisioning has printed the address,
   request the entry from the Gnosis VPN project through support@gnosisvpn.com,
   the contact address on the project's site (https://vpn.gnosis.eth.limo/),
   which also links the Gnosis Discord (https://discord.gg/gnosis).

The client needs no configuration change for a listed exit: it uses the session
targets built into it (`172.30.0.1`).

## Acceptance gate

A clean `gvpn-exit-status` on a development network is not acceptance for a
site; it checks none of the following. A device is ready to serve clients only
when:

- it is provisioned and funded on the confirmed production network and
  endpoints;
- its node address is on the GnosisVPN client's destination list, requested from
  the Gnosis VPN project through support@gnosisvpn.com;
- a GnosisVPN client session through it succeeded from outside the staging
  network.

Tooling for this gate is [open work](roadmap.md#fleet-and-onboarding).

## After the installation

| Task                                         | Read                                            |
| -------------------------------------------- | ----------------------------------------------- |
| Log in from the LAN, add or replace SSH keys | [Local access](local-access.md)                 |
| Reach a managed device through the bastion   | [Bastion](bastion.md#reaching-a-device)         |
| Get back into a device that lost its keys    | [Recovery stick](recovery.md)                   |
| Update devices                               | [Publish and promote](publish-image.md)         |
| Move a device to another image repository    | [Switch registry](switch-registry.md)           |
| Move a device from hoprd v4 to v5            | [hoprd v4 to v5](hoprd-v5-migration.md)         |
| Rehearse an installation in QEMU             | [Build system](build.md#qemu-install-rehearsal) |
