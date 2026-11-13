# Gnosis VPN ExitOS

GnosisVPN exit-node OS for the Beelink SER8 and GEEKOM A8: Fedora IoT (bootc)
running `hoprd` and `gnosis_vpn-server`, with private-range isolation, per-peer
traffic shaping sized from a boot-time uplink measurement, an IP blocklist,
TPM-sealed credentials, signed image updates and greenboot rollback.

A device is set up by two independent choices
([which ones](docs/first-install.md#choose-your-setup)); every combination is
supported:

- Management, chosen when its installer is built:
  - **Managed**: installed and provisioned before it goes to its site, then
    administered remotely through a reverse SSH tunnel to a support bastion its
    operator runs.
  - **Unmanaged**: installed by the operator who runs it, and reached over SSH
    from its LAN only. No bastion and no support tunnel are involved.
- Target:
  - **Hardware**: a Beelink SER8 or GEEKOM A8, installed from a USB stick.
  - **VM**: an Incus VM sized with at least 8 vCPUs and 16 GiB RAM
    ([Incus VM](docs/incus.md)).

CI publishes a ready-to-install ISO on every merge, so an operator does not have
to build one. It is unmanaged, serves hardware and VMs, and has no SSH key:
configure access on the console (keyboard and monitor, or the VM console) with
your own key before provisioning
([first access on the console](docs/local-access.md#first-access-on-the-console)).

| Task                                      | Read                                         |
| ----------------------------------------- | -------------------------------------------- |
| Get onboarded as a developer              | [Intro deck](docs/intro/README.md)           |
| Install, provision and connect over SSH   | [First install](docs/first-install.md)       |
| Log in from the LAN and manage SSH keys   | [Local access](docs/local-access.md)         |
| Prepare a support bastion (managed setup) | [Bastion](docs/bastion.md)                   |
| Build and test locally or in QEMU         | [Build system](docs/build.md)                |
| Install the ISO into an Incus VM          | [Incus VM](docs/incus.md)                    |
| Publish a canary update                   | [Publish runbook](docs/publish-image.md)     |
| Move an installed v4 node to v5           | [hoprd v4 to v5](docs/hoprd-v5-migration.md) |
| Get back into a device that lost its keys | [Recovery stick](docs/recovery.md)           |
| Understand runtime behaviour              | [Architecture](docs/architecture.md)         |
| Check gaps and planned work               | [Roadmap](docs/roadmap.md)                   |
| Change this repository                    | [Contributor guidance](AGENTS.md)            |

```sh
nix develop -c just test  # shellcheck + unit tests; no image build or VM
```

Every image build needs `GVPN_IMAGE_REPO` and `GVPN_COSIGN_PUB`, the public half
of the key that signs the updates the devices will accept; the repository in the
checked-in configuration is a placeholder
([deployment inputs](docs/build.md#deployment-inputs)). Blokli URL is configured
per-device at provisioning time, where `finalize --blokli-url` is required; the
default endpoint to pass is https://blokli.piz-palu.gnosisvpn.io. An installer
ISO **wipes the install disk (the only internal disk it finds, or the one
`GVPN_INSTALL_DISK` names) when booted**, and one built for a managed device
contains a per-device enrollment key; follow the install runbook. The support
bastion is optional and operated outside this repository
([how to prepare one](docs/bastion.md)); the fleet backend is not implemented,
part of the [roadmap](docs/roadmap.md#fleet-and-onboarding).

Licensed under the [MIT License](LICENSE); third-party components keep their own
licenses ([notices](THIRD-PARTY-NOTICES.md)). Report vulnerabilities privately
as described in the [security policy](SECURITY.md).
