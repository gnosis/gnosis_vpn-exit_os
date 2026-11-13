# Build system

Builds the OS image, installer ISOs for hardware and Incus VMs, a QEMU test
appliance and an Incus VM install path. Runtime behaviour is in
[architecture.md](architecture.md), releasing in
[publish-image.md](publish-image.md).

Run every command from the repository root inside the devshell
(`nix develop -c ...`). The devshell exists for x86_64 and aarch64 Linux and for
aarch64 and x86_64 Darwin. On Linux it provides the test, publishing and VM
tools, including OVMF on x86_64; the host provides Docker daemon access (or root
with Podman) and, for the VM harness, KVM. On Darwin it provides the test,
linting, pin-check, promotion and recovery packing tools, plus the GNU userland
(`readlink -f`, `stat -c`, `flock`, `sed -i`) that the scripts call, but no VM
tools: KVM, OVMF, swtpm and `ip` only exist on Linux. The Incus recipes use the
host's Incus installation, which is Linux-only and not part of the devshell
([Incus VM](incus.md)).

## Sources of truth

| Source                                                                                       | Owns                                                                                                                               |
| -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`justfile`](../justfile)                                                                    | Commands, image tag, default channel and SSH key path                                                                              |
| [`flake.nix`](../flake.nix), [`flake.lock`](../flake.lock)                                   | Devshell tools                                                                                                                     |
| [`image/versions.env`](../image/versions.env)                                                | Base image digest, application versions and hashes, netdata version; bump by reviewed PR                                           |
| [`image/Containerfile`](../image/Containerfile), [`image/build/`](../image/build/)           | Release download and verification, packages, blocklist snapshot, deployment configuration, smoke tests, `bootc container lint`     |
| [`image/rootfs/`](../image/rootfs/)                                                          | Files copied into the OS                                                                                                           |
| [`keys/`](../keys/)                                                                          | Public keys only: release signing keys and the netdata repo key. The image-update key is an operator input, not a repository file. |
| [`image/bib/`](../image/bib/), [`tools/render-bib-config.sh`](../tools/render-bib-config.sh) | Installer and qcow2 templates, per-device input validation                                                                         |
| [`tools/`](../tools/)                                                                        | Builder, disk builds, publishing, QEMU harness                                                                                     |
| [`tests/unit/`](../tests/unit/), [`tests/integration/`](../tests/integration/)               | Tests                                                                                                                              |

The build context contains only `image/` and `keys/` (`.containerignore`), so
never put a private key under `keys/`.

## Commands

| `nix develop -c just ...`     | Result                                                                                                                                                                                                                            |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test`                        | shellcheck, then all bats suites; builds and boots nothing                                                                                                                                                                        |
| `lint`                        | shellcheck only, including `tests/integration/`                                                                                                                                                                                   |
| `check-pins`                  | Verifies that the pinned base, hoprd image, builder and bootc-image-builder references still resolve (needs network)                                                                                                              |
| `update-pins`                 | Moves the base, builder and bootc-image-builder pins to the newest reference their tags offer, then runs `check-pins`; the hoprd image digest moves with its binary hashes by hand. Review the diff and open a PR (needs network) |
| `build`                       | `localhost/gvpn-exit-os:dev` in the builder's container storage                                                                                                                                                                   |
| `iso`                         | `build`, then the key-configured installer `output/iso/bootiso/install.iso` for hardware and Incus VMs                                                                                                                            |
| `iso-console`                 | The same ISO with no SSH key; first access is the console                                                                                                                                                                         |
| `iso-console-only`            | `iso-console` from an image already in the builder's storage (CI)                                                                                                                                                                 |
| `qcow2`                       | `build`, then a disk under `output/qcow2/` (not used by `tools/vm.sh`)                                                                                                                                                            |
| `vm-install`                  | Installs the ISO into a fresh VM; deletes `output/vm/`                                                                                                                                                                            |
| `vm-run`                      | Boots the installed VM on the terminal; `Ctrl-a x` quits                                                                                                                                                                          |
| `vm-ssh [command]`            | SSH as devops to localhost port 2222                                                                                                                                                                                              |
| `publish-iso [VERSION]`       | Signs and pushes the installer ISO, then moves `iso-canary`                                                                                                                                                                       |
| `push-iso [VERSION]`          | Signs and pushes the installer ISO without moving a channel tag (idempotent for one build; refuses a version published from another build)                                                                                        |
| `tag-iso VERSION`             | Verifies an already published version against `GVPN_COSIGN_PUB`, then moves `iso-canary` to it                                                                                                                                    |
| `pull-iso REF`                | Pulls a published ISO into `output/published-iso/`, verifies the signature and the checksums of the ISO, its version and its target, and prints its path                                                                          |
| `incus-install [ISO]`         | Builds an ISO with `iso` and boots the installer in a new Incus VM; with `ISO`, installs that file                                                                                                                                |
| `incus-install-published REF` | Pulls a published ISO and installs it in a new Incus VM                                                                                                                                                                           |
| `incus-run`                   | Removes the installer disk and boots the installed Incus VM                                                                                                                                                                       |
| `incus-ssh [command]`         | SSH as devops to the Incus VM's bridge address                                                                                                                                                                                    |
| `incus-console`               | Attaches to the Incus VM console; `Ctrl-a q` leaves it                                                                                                                                                                            |
| `incus-destroy`               | Deletes the Incus VM, its disk and its vTPM                                                                                                                                                                                       |
| `test-integration PHASE`      | Checks the running VM over SSH ([phases](#tests))                                                                                                                                                                                 |
| `usb DEVICE [ISO]`            | Writes the built ISO, or `ISO`, to a whole USB disk after typed confirmation, destroying its contents                                                                                                                             |
| `recovery-build`              | Builds the recovery stick image into `output/recovery/BOOTX64.EFI` ([recovery](recovery.md))                                                                                                                                      |
| `recovery-image [KEYS_FILE]`  | Packs the stick into one compressed image to send to a site                                                                                                                                                                       |
| `recovery-usb DEVICE`         | Writes the recovery stick to a whole USB disk, destroying its contents                                                                                                                                                            |
| `publish`                     | Signs and pushes the built image ([runbook](publish-image.md))                                                                                                                                                                    |
| `push`                        | Signs and pushes the built image without moving a channel tag                                                                                                                                                                     |
| `promote VERSION CHANNEL`     | Promotes a version to canary or stable after signature verification                                                                                                                                                               |

`vm-install`, `vm-run` and `test-integration` drive the QEMU harness, so they
need the Linux devshell. `incus-install`, `incus-run`, `incus-ssh`,
`incus-console`, `incus-destroy` and `incus-install-published` drive a Linux
host's Incus installation ([Incus VM](incus.md)); they need the devshell for the
build, `jq` and `oras` but take `incus` from the host. `build`, `iso`,
`iso-console`, `qcow2`, `recovery-build`, `publish` and `push` run through the
Podman builder (`tools/builder.sh`), which expects a Linux container host: root
with Podman or a Docker daemon. `publish-iso`, `push-iso`, `tag-iso` and
`pull-iso` run on the host and use `oras` and the host's registry login; the
publishing recipes publish the ISO that `iso-console` already built. `usb` and
`recovery-usb` run on the host instead, because they write a stick with `sudo`
and address a block device. `recovery-image` also runs on the host, packs the
stick into one file and works on Darwin as well.

Disk images track the `canary` channel unless built with `channel=stable`
(`just channel=stable iso`).

`tools/builder.sh` runs rootful Podman directly when invoked as root with Podman
installed. Otherwise it runs Podman in a privileged, host-networked Docker
container whose storage persists in the volume `gvpn-exit-os-storage`; inside it
the repository is mounted read-only and only `output/` is writable.

## Deployment inputs

Image builds need the target container repository and the public half of the key
that signs the updates the image will accept:

```sh
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'
```

- `GVPN_IMAGE_REPO`: lowercase `registry[:port]/path`, without scheme, tag or
  digest. It scopes the image's signature policy, and disk builds tag the image
  `<repo>:<channel>` so the installed system tracks that tag. Publish with the
  same value.
- `GVPN_COSIGN_PUB`: the public half of your image-update key pair, which you
  create once with `cosign generate-key-pair`
  ([publish runbook](publish-image.md)). It is not in the repository: every
  operator has to ship devices that trust the key that operator can sign with.
  The build fails without it, because `policy.json` would reject every update.
  Keep the pair: the devices you install cannot accept updates from any other
  key, and losing the private half means re-installing them.

Where the private half lives follows how you publish: from a workstation it
stays offline, and the CI release workflow keeps it as a secret of its `release`
environment ([CI](#ci)).

`GVPN_IMAGE_REPO` is validated before the builder starts, and
`image/build/configure-image.sh` renders it into `/etc/containers/policy.json`;
the `example.org` value in the checked-in files is a placeholder that stays
untouched. Changing `GVPN_IMAGE_REPO` does not move existing devices; that needs
a planned origin and trust migration.

Devices pull their updates without credentials: nothing in the image carries a
registry login, so the repository in `GVPN_IMAGE_REPO` must allow anonymous
pulls. A private registry is not supported today
([roadmap](roadmap.md#device-gaps)).

Blokli URL is not baked into the image; `hoprd.cfg.yaml` carries a placeholder
to satisfy schema validation at build time. The live Blokli URL is supplied
per-device at provisioning time (`finalize --blokli-url <URL>`, which is
required); the default endpoint to pass is https://blokli.piz-palu.gnosisvpn.io.
It is written to `/etc/hoprd-v5/hoprd.env.d/10-provisioned.env`; a device
updated from v4 keeps `/etc/hoprd/hoprd.env.d/10-provisioned.env` for the v4
cleanup and has hoprd held stopped until
[`gvpn-exit-hoprd-migrate`](hoprd-v5-migration.md) writes the v5 file. At every
start `hoprd-run.sh` renders that URL into a runtime copy of the configuration,
because the PIX pool has a second `blokli_url` that no environment variable
overrides.

The installer ISO also reads:

| Variable              | Value                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GVPN_INSTALL_DISK`   | The disk the kickstart wipes. Default `auto`, also when set but empty: the installer picks the only internal disk, ignoring USB and other removable disks and its own install media, and stops with an error when there is not exactly one. A kernel name (`nvme0n1`, `sda`, `vda`) pins the disk, which a device with more than one internal disk needs. It is an installer input; the container image never sees it. |
| `GVPN_CONSOLE_ACCESS` | `1` builds an ISO with no installer SSH key and an expired `devops` console password; `just iso-console` sets it. `just iso` stays key-configured.                                                                                                                                                                                                                                                                     |
| `GVPN_ISO`            | The ISO path that `publish-iso`, `push-iso` and `usb` use instead of `output/iso/bootiso/install.iso`                                                                                                                                                                                                                                                                                                                  |
| `GVPN_ISO_DIR`        | Where `pull-iso` downloads to, default `output/published-iso`                                                                                                                                                                                                                                                                                                                                                          |
| `GVPN_ISO_VERIFY_DIR` | Where `tag-iso` downloads the version it verifies, removed afterwards; default `output`                                                                                                                                                                                                                                                                                                                                |

## CI

`.github/workflows/` builds on every pull request, pushes a signed image on
every merge to `main`, and promotes manually. The release workflows push to
Google Artifact Registry and log in through Workload Identity Federation: GitHub
hands the job an OIDC token, the `gnosisvpn-gh-pool` provider in
`gnosisvpn-production` exchanges it for the
`download-gnosisvpn-gh-sa@gnosisvpn-production.iam.gserviceaccount.com` service
account, and its access token logs Docker in as `oauth2accesstoken`. No registry
credential is stored in GitHub. That service account needs a
`roles/iam.workloadIdentityUser` binding for this repository's
`attribute.repository` principal set and `roles/artifactregistry.writer` on the
repositories below. That binding trusts every workflow run in the repository,
not only the `release` environment, so push access is not the control: devices
accept only images signed with the key below. Point the workflows at the
repositories with repository settings:

| Kind     | Name                     | Value                                                                                                                                               |
| -------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| variable | `GVPN_IMAGE_REPO`        | the repository to push to                                                                                                                           |
| variable | `GVPN_ISO_REPO`          | optional: a repository of its own for the installer ISO, in the same `registry[:port]/path` form; without it the ISO is pushed to `GVPN_IMAGE_REPO` |
| variable | `GVPN_COSIGN_PUB`        | public half of the image-update key pair, `BEGIN PUBLIC KEY` block and all                                                                          |
| secret   | `GVPN_COSIGN_KEY`        | private half of the same pair                                                                                                                       |
| secret   | `GVPN_COSIGN_PASSPHRASE` | its passphrase, if it has one                                                                                                                       |

The signing key and its passphrase belong to a GitHub environment named
`release`: create it in the repository settings, restrict its deployment
branches to `main` and add required reviewers. That branch restriction is what
keeps a release to `main`: the workflows also check `github.ref` themselves, but
a dispatch from another branch runs that branch's copy of the workflow, so the
in-job check is a convenience and not the control. GitHub creates an environment
named `release` on first use if it does not exist, and that one has no
restrictions, so create and restrict it before the secrets are added. Store the
key there and not at repository level, because a repository secret is readable
by any workflow run in the repository, including one from an unreviewed branch;
a signing key in that place lets anyone who can push a branch sign an image
every device accepts. Whoever can run the release workflow can sign, so the
environment's reviewers and their accounts are the protection.

The merge workflow also builds the installer ISO and publishes it as a signed
OCI artifact next to the image (or in `GVPN_ISO_REPO`, when that is set) as an
immutable `iso-<version>`, so an operator can pull it without building locally,
for hardware or an Incus VM. That ISO is unmanaged, picks its install disk
itself and has no installer SSH key: its first access is the console, where the
operator adds their own key
([first access on the console](local-access.md#first-access-on-the-console)). A
managed ISO carries an enrollment private key, so it is built per device and
never published. Like the image, `iso-canary` moves separately with
`just tag-iso VERSION` after the matching image was promoted. Pull requests
build the console ISO too and publish nothing.

The ISO is pushed before the image. A version names one build: when the image
push fails, a rerun of the job rebuilds the image, finds `iso-<version>`
published with another embedded image ID and stops at the ISO step, so the
rebuilt image is never pushed under that version. `iso-<version>` then exists
without `<repo>:<version>`; release again from a new commit.

The push logs in with `docker login`, so a registry that takes a user and a
password (or a token) needs no workflow change. Pull requests from forks never
receive the secrets, so the signed build and push jobs run for `main` only
(environment `release`); that is deliberate, so no secret is ever exposed to a
fork.

## Trust and reproducibility

- The base image and bootc-image-builder are digest-pinned. The Podman builder
  image uses Podman's `-immutable` version tag instead: quay garbage-collects
  the manifests behind its daily-rebuilt tags, so a pinned digest of one stops
  resolving. For the same reason, a build fails with "manifest unknown" once the
  tags behind `FEDORA_IOT_IMAGE` in
  [`image/versions.env`](../image/versions.env) have moved on. `just check-pins`
  checks every pin against its registry and names the variable and the reference
  when one no longer resolves; CI runs it before building. `just update-pins`
  moves the base image and bootc-image-builder to the current digest of their
  tags (`fedora-iot:44`, `latest`, resolved for linux/amd64) and Podman to its
  newest `vX.Y.Z-immutable` tag. It never changes the Fedora major version: edit
  the tag in `versions.env` for that. The hoprd PIX image digest and its two
  binary sha256 values are one manual pin: bump the tag, digest and both hashes
  together.
- hoprd v4, hopli and gnosis_vpn-server are sha256-pinned and verified with
  `gpgv` against the release keys in `keys/`; Foundry's `cast` (used by the
  v4-to-v5 helper for the old Safe transfer) is sha256-pinned against the
  published release tarball. The v5 `hoprd` and `hoprd-cfg` come from the
  digest-pinned PIX-enabled hoprd OCI image (the GitHub release binary is built
  without `strategy-pix-curvy`); their sha256 values are checked again in the
  build, and the image also supplies the Curvy proving artifacts under
  `/usr/share/gvpn-exit/curvy-zk`. netdata is version-pinned from its repository
  with package and metadata GPG checks.
- Other RPMs and the blocklist snapshot come from live sources, so builds are
  not byte-reproducible.
- `just build` labels the image with `git describe --tags --always --dirty`
  (`dev` when unavailable). Release only committed, reviewed source.
- `GVPN_COSIGN_PUB` becomes `/etc/pki/containers/gvpn-exit-os.pub`, the key
  devices verify updates with ([updates](architecture.md#updates)). It travels
  into the build as a base64 build arg, and the build fails without it.

## Disk images

`tools/render-bib-config.sh` runs on the host, so key files may live outside the
repository. It writes the bootc-image-builder config to a 0600 temporary file
under `output/` that is deleted when the recipe ends. A key-configured ISO takes
the devops public key from `GVPN_DEVOPS_SSH_KEY` (default `ssh_id.pub`; only the
first key line is used) and accepts the key types the recovery stick accepts,
security keys included. With `GVPN_CONSOLE_ACCESS=1` the key file is not read:
`devops` gets the temporary password `gvpn-exit`, the kickstart expires it, and
no SSH key is installed. The serial getty is enabled only when the installed
system runs in a VM; on hardware the console is the keyboard and monitor (tty1).

For a managed device, administered through a support bastion
([the setups](first-install.md#choose-your-setup)), the ISO also carries the
first-access tunnel:

| Variable                   | Value                                                            |
| -------------------------- | ---------------------------------------------------------------- |
| `GVPN_BASTION`             | `user@host` or `ssh://user@host:port`                            |
| `GVPN_SUPPORT_PORT`        | This device's reverse port on the bastion's loopback, 1024-65535 |
| `GVPN_ENROLL_KEY`          | OpenSSH enrollment private key file                              |
| `GVPN_BASTION_KNOWN_HOSTS` | Non-empty known_hosts file for the bastion                       |

The four are given together or not at all; the build refuses a partial set.
Without them the ISO installs an unmanaged device that is reached from its LAN
only ([local access](local-access.md)), and it carries no secret.

**With the bastion inputs, the ISO, its rendered config and the USB stick
contain the enrollment private key** (base64 is not encryption): build one ISO
per device, protect all three and never publish it. bootc-image-builder also
writes a `manifest-*.json` next to the image, and that file embeds the
kickstart, enrollment key included; `tools/build-disk.sh` deletes it once the
build ends and leaves such an ISO readable by its owner only (0600). Copying it
elsewhere does not keep that protection. **Booting the ISO wipes its install
disk (the one `GVPN_INSTALL_DISK` names, or the only internal disk the installer
finds) without asking.** The kickstart installs the
[pinned layout](architecture.md#persistent-state), creates devops with the key
and locks devops' password (a console-configured ISO instead sets a temporary
expired devops password and no key), locks root's password, sets UTC and
reboots; with the bastion inputs it also writes `/etc/gvpn-exit/support.env` and
`bastion_known_hosts` (0644) and `enroll.key` (0600). For an install follow
[first-install.md](first-install.md).

The qcow2 template only creates devops and requests a root filesystem of at
least 20 GiB.

Every ISO build (`tools/build-disk.sh`) writes `install.iso.version` and
`install.iso.target` beside the ISO, after removing the ones of an earlier
build. The version is the version label of the image the ISO embeds, not the
checkout's. The target sidecar is read from the rendered kickstart: the disk
(`disk=auto` or the pinned name), whether the ISO carries bastion enrollment
data (`enrollment=none|bastion`) and whether access is `key` or `console`; it
also records the embedded image's ID (`image=`) and the ISO's checksum
(`sha256=`). Publishing and pulling require `disk=auto`, `enrollment=none` and
`access=console`, so a publisher cannot push an installer pinned to one disk, an
ISO with a private enrollment key or an ISO with a shared `devops` key by
mistake. `tools/publish-iso.sh` refuses an ISO without a version sidecar or
whose target sidecar does not hold the ISO's own `sha256`. It writes
`install.iso.sha256`, the checksums of the ISO and both sidecars, signs that
file, and pushes the ISO, the checksum file, its signature bundle
(`install.iso.sha256.sigstore.json`), the version and the target as one OCI
artifact; only then does it move `iso-canary` when asked.

`tools/pull-iso.sh` verifies, in this order: the signature of the checksum file
against `GVPN_COSIGN_PUB`; that the checksum file lists the ISO, the version and
the target; the checksum of each of the three; the target values above; and, for
a version (not `canary`), that the signed version is the one asked for. An ISO,
version or target that the key did not sign together is refused, which includes
an older signed ISO re-pushed under a newer version. What it does not verify is
the tag: `canary` can be pointed at any ISO that was published with the key, an
older one included, so pull a version when that matters. The manifest annotation
with the embedded image's ID is not signed and is only used by the publisher
([CI](#ci)).

`just tag-iso VERSION` pulls that version, verifies it the same way and only
then moves `iso-canary`; the download is removed afterwards
(`GVPN_ISO_VERIFY_DIR`, default `output/`).

## QEMU harness

`tools/vm.sh` boots a q35/KVM VM with OVMF (writable variables), swtpm TPM2, 4
GiB RAM, 4 vCPUs, a 64 GiB NVMe disk and one virtio NIC (renamed `lan0`). User
networking forwards localhost port 2222 (`VM_SSH_PORT`) to SSH. State lives in
`output/vm/`. `tools/vm.sh run-headless` writes the console to
`output/vm/console.log` instead of the terminal.

## Incus harness

`just incus-install` installs the appliance into an Incus VM on a Linux host
([runbook](incus.md)). It builds the key-configured ISO with `just iso`, which
picks the VM's root disk at install time like the internal disk of hardware,
then creates the instance, adds a vTPM and boots the installer. `just incus-run`
removes the installer disk and boots the installed system; `just incus-ssh`
connects as `devops`. The production default is **8 vCPUs, 16 GiB RAM and a 64
GiB disk** (minimum recommended), overridable with `GVPN_INCUS_CPUS`,
`GVPN_INCUS_MEMORY` and `GVPN_INCUS_DISK_SIZE`; `GVPN_INCUS_VM` names the
instance (default `gvpn-exit`).

Incus supplies the firmware, TPM and DHCP bridge; the guest still renames its
virtio NIC to `lan0` and accepts SSH from RFC1918 sources only. The bridge's
range must not contain `172.30.0.1` or overlap `10.128.0.0/24`, and it must be a
managed network with DHCP. The integration phases take the guest address from
`VM_SSH_HOST` (default `127.0.0.1`) and `VM_SSH_PORT` (default 2222) instead of
QEMU's fixed forward, so they can run against the Incus VM with
`VM_SSH_PORT=22`; re-resolve the address after a reboot if the lease changed.

CI publishes a ready-to-install ISO as `iso-<version>`; after the matching image
is promoted, `just tag-iso VERSION` also moves `iso-canary`.
`just incus-install-published REF` pulls it, verifies its signature and installs
it in one step; `just pull-iso REF` only fetches it. The published ISO has no
bastion inputs and no SSH key; configure access on the VM console before
provisioning ([Incus VM](incus.md#on-the-console)). A managed VM uses an ISO
built with `just iso` and the four bastion inputs ([publishing](#ci)).

### First-install rehearsal

The rehearsal installs a device with a bastion: a throwaway one on the host
(`tests/integration/bastion.sh`), which the VM reaches as `10.0.2.2`.
`VM_SSH_KEY` is the private key matching `GVPN_DEVOPS_SSH_KEY`. The harness uses
it; `just vm-ssh` does not, so pass `-i` there if your agent does not offer the
key. Keep port 2222, which `vm-ssh` hardcodes.

Terminal 1:

```sh
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'
export GVPN_DEVOPS_SSH_KEY="$HOME/.ssh/id_ed25519.pub"
nix develop -c just test
nix develop -c tests/integration/bastion.sh start
eval "$(nix develop -c tests/integration/bastion.sh env)"
nix develop -c just iso vm-install
nix develop -c just vm-run   # keep running
```

Terminal 2 (`provision` refuses to run without `VM_BLOKLI_URL`; replace the
example with your test network's endpoint; the default endpoint is
https://blokli.piz-palu.gnosisvpn.io unless the network needs another one):

```sh
export VM_SSH_KEY="$HOME/.ssh/id_ed25519"
export VM_BLOKLI_URL='https://blokli.example.org'
eval "$(nix develop -c tests/integration/bastion.sh env)"
nix develop -c just test-integration unprovisioned
nix develop -c just test-integration enroll
nix develop -c just test-integration provision   # dummy Safe; reboots and waits
nix develop -c just test-integration provisioned
nix develop -c just test-integration address
```

Afterwards quit QEMU and run `nix develop -c tests/integration/bastion.sh stop`.

The rehearsal ISO points at `10.0.2.2` and overwrites the path a device ISO
uses. **Never flash it onto hardware**; rebuild with device inputs right before
writing a stick.

The `update` phase is not a local test. It needs `GVPN_IMAGE_REPO` and a newer
signed image published to the VM's channel ([runbook](publish-image.md)), and it
writes `<repo>:unsigned-probe` with the host's registry credentials. Its
rollback-trigger regression also needs a second, newer digest published while it
runs; without one it prints a SKIP line. Never run it against a channel that
real devices track.

## Tests

The unit suites run the scripts against sandboxes, with recording command mocks
on `PATH` (`tests/unit/helpers.bash`). The image build separately checks binary
versions, the shipped hoprd config, sudoers syntax and
`bootc container lint --fatal-warnings`.

`cpu.bats` drives the image's tmpfiles rule with `systemd-tmpfiles`, so it skips
on Darwin. Every other unit suite runs in the Darwin devshell; run `just test`
in the Linux devshell (CI does) before pushing.

The integration phases run over SSH against the installed VM: real systemd, TPM
and SELinux, no mocks.

| Phase           | Scope                                                                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `unprovisioned` | Provisioning gate; with `GVPN_BASTION` the installer enrollment files and enrollment tunnel, without it their absence (LAN-only device)                                      |
| `enroll`        | Device access through the bastion                                                                                                                                            |
| `provision`     | Dummy-Safe provisioning and reboot                                                                                                                                           |
| `provisioned`   | Services, credential handling, WireGuard and shaping, capacity measurement and the pool derived from it, address initialization, netprobe, support tunnel                    |
| `address`       | Operator refresh, runtime environment, preservation on discovery failure                                                                                                     |
| `update`        | Unsigned-image rejection, download-only staging, unprepared reboot, rollback-trigger regression, apply-now, snapshot and ownership records, saved address and support access |

`unprovisioned`, `provisioned` and `update` also run common checks: `lan0`
naming and RPS, socket buffers, firewall isolation, IPv6, loopback-only
monitoring, blocklist, greenboot, masked stock updates and SELinux (ignoring
bootc's known `chcon` probe denial).

None of this proves funded announcement, NAT/CGNAT reachability, client
sessions, packet-level isolation, throughput or DB restore after a forced
rollback ([roadmap](roadmap.md#tests-not-yet-built)). The dummy Safe leaves
hoprd unfunded with its API closed.

All artifacts (disk images, VM state, test bastion keys and logs, publish
archives) go to the git-ignored `output/`.
