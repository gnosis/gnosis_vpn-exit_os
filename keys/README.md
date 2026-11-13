# Pinned public keys

Public keys only: the build context is `image/` and `keys/`
([`.containerignore`](../.containerignore)), so no private key belongs here.

| File | Verifies | Used in | Key id | Fingerprint |
|---|---|---|---|---|
| `hoprnet-release.asc` | the detached signatures of the `hoprd`, `hoprd-cfg` and `hopli` release assets | `image/Containerfile` fetch stage, through `image/build/fetch-release.sh` (`gpgv`) | `7601 07FD 6230 3CBC` | `478E 1B4C BE4F 8B29 C91C 7D59 7601 07FD 6230 3CBC` |
| `gnosisvpn-release.asc` | the detached signature of the `gnosis_vpn-server` release asset | the same fetch stage | `84F7 3FEA 46D1 0972` | `9A30 8031 FD3B FE8E DBF5 076D 84F7 3FEA 46D1 0972` |
| `netdata-repo.asc` | the netdata repository's metadata and packages | `image/Containerfile` copies it to `/etc/pki/rpm-gpg/RPM-GPG-KEY-netdata`, the `gpgkey` of `image/build/netdata.repo` | `9DD4 A74C ECFA 8F4F` | `6E15 5DC1 5390 6B73 765A 74A9 9DD4 A74C ECFA 8F4F` |

- `hoprnet-release.asc`: ed25519, uid `Hoprnet`.
- `gnosisvpn-release.asc`: ed25519, uid `GnosisVPN`.
- `netdata-repo.asc`: rsa4096, uid `Netdatabot (Netdata Repository Signing Key) <bot@netdata.cloud>`.

A change to a key file has to be checked against the fingerprint its upstream
project publishes. Print what a file holds with:

```sh
gpg --show-keys --with-fingerprint keys/<file>
```

The image-update key is not in this directory: its public half is the operator
input `GVPN_COSIGN_PUB`, because every operator ships devices that trust the key
that operator can sign with ([`.gitignore`](../.gitignore) keeps a copy out of
the repository, [build](../docs/build.md) covers the input).
