# Third-party notices

What this repository carries from others, and what an image, installer ISO or
recovery stick built from it redistributes. Every component below keeps its own
license; the [MIT License](LICENSE) covers this repository's own files only.

## Carried in this repository

| File                                                                              | Origin                                               | License                                                                                |
| --------------------------------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `keys/hoprnet-release.asc`, `keys/gnosisvpn-release.asc`, `keys/netdata-repo.asc` | public keys published by HOPR, GnosisVPN and netdata | not software; the terms of the project that signs with each key apply to what it signs |

## Redistributed in a built image

None of these is in this repository. The build downloads them from the location
named in `image/versions.env` or installs them from Fedora's repositories
(`image/Containerfile`):

| Component                                                          | Origin                                                                     | License                                                                                                                                   |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Fedora IoT base image                                              | quay.io/fedora/fedora-iot                                                  | see upstream                                                                                                                              |
| hoprd, hoprd-cfg (v5 PIX build)                                    | github.com/hoprnet/hoprd, published as an OCI image                        | GPL-3.0                                                                                                                                   |
| hoprd v4 (cleanup helper)                                          | github.com/hoprnet/hoprd releases, v4.1.3                                  | GPL-3.0                                                                                                                                   |
| Curvy proving artifacts                                            | github.com/0xCurvy/rs-sdk release assets, the version the hoprd image pins | MIT                                                                                                                                       |
| hopli                                                              | github.com/hoprnet/hopli                                                   | GPL-3.0                                                                                                                                   |
| cast (Foundry)                                                     | github.com/foundry-rs/foundry                                              | MIT OR Apache-2.0                                                                                                                         |
| gnosis_vpn-server                                                  | github.com/gnosis/gnosis_vpn-server                                        | LGPL-3.0                                                                                                                                  |
| netdata                                                            | netdata's Fedora repository, netdata/netdata                               | GPL-3.0; the dashboard it ships, the Netdata Cloud UI, is under the Netdata Cloud UI License (NCUL1), which is not an open-source license |
| FireHOL level1 blocklist snapshot                                  | github.com/firehol/blocklist-ipsets                                        | see upstream                                                                                                                              |
| other packages (WireGuard tools, iptables-nft, ipset, chrony, ...) | Fedora repositories                                                        | see upstream                                                                                                                              |

The installer ISO adds Fedora's installer to the image, and the recovery stick
is a Fedora kernel with a dracut initrd (systemd, busybox, util-linux, ...)
built in the base image; both come from Fedora's repositories and keep their
licenses (see upstream).

Whoever distributes a built image, ISO or recovery stick is responsible for
meeting those licenses, including the license texts and the source that they
require.
