# gvpn-exit-os

GnosisVPN exit-node OS for Beelink SER8 and GEEKOM A8, based on Fedora
IoT/bootc. Before changing behaviour, read [architecture](docs/architecture.md),
[build](docs/build.md) and [roadmap](docs/roadmap.md). Keep docs in sync with
code. A device is either managed, administered through a support bastion, or
unmanaged, reached from its LAN only, and runs on hardware or in an Incus VM
([the setups](docs/first-install.md#choose-your-setup)); the bastion is outside
this repository ([how to prepare one](docs/bastion.md)); the fleet backend is
not implemented, part of the [roadmap](docs/roadmap.md#fleet-and-onboarding).

## Layout

| Path                                  | What                                                                                                                                                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `image/Containerfile`                 | The OS image. Pins come from `image/versions.env` as build args.                                                                                                                                       |
| `image/versions.env`                  | Base image digest, app versions + sha256, netdata version. Bump by PR only.                                                                                                                            |
| `image/rootfs/`                       | Copied into the image: units, drop-ins, scripts, configs; deployment defaults are rendered during the build.                                                                                           |
| `image/rootfs/usr/libexec/gvpn-exit/` | Bash runtime scripts; `lib.sh`, `checks.sh`, `public-ip.sh` are sourced helpers.                                                                                                                       |
| `image/rootfs/usr/bin/`               | Operator CLIs: provisioning, support, status, hoprd address refresh and the hoprd v4-to-v5 migration.                                                                                                  |
| `image/rootfs/usr/lib/greenboot/`     | Required software checks may trigger rollback; wanted connectivity checks cannot.                                                                                                                      |
| `image/build/`                        | Build-time helpers (release download + GPG verify, blocklist snapshot, netdata repo, deployment configuration).                                                                                        |
| `image/bib/`                          | bootc-image-builder configs (installer ISO, QEMU qcow2).                                                                                                                                               |
| `image/recovery/`                     | Recovery stick image: a Unified Kernel Image that adds operator keys to an appliance and opens a support window.                                                                                       |
| `keys/`                               | Pinned public keys: HOPR + GnosisVPN release keys and the netdata repo key. The image-update key is operator-specific and comes in as `GVPN_COSIGN_PUB`, never from this repository.                   |
| `tools/`                              | Rootful Podman builder (direct or through Docker), host-side installer rendering, disk builds, publishing, recovery sticks and QEMU.                                                                   |
| `tests/unit/`                         | bats suites, run against a sandbox with recording command mocks.                                                                                                                                       |
| `tests/integration/`                  | SSH checks against an installed VM and a throwaway bastion.                                                                                                                                            |
| `docs/`                               | Design (`architecture.md`, `build.md`, `roadmap.md`), operator runbooks (`first-install.md`, `local-access.md`, `bastion.md`, `publish-image.md`, `recovery.md`, `incus.md`, `hoprd-v5-migration.md`). |

## Commands

Everything runs inside the devshell: `nix develop -c just <recipe>`.

The devshell exists for `x86_64-linux`, `aarch64-linux`, `aarch64-darwin` and
`x86_64-darwin`. Darwin runs the unit suites, linting, `check-pins`, `promote`
and the recovery stick packing (`recovery-image`) with a GNU userland from the
devshell; image, disk and `publish`/`push` recipes need a Linux container host,
the USB recipes write a block device on the host and need a Linux machine, and
the VM harness needs x86_64 Linux with KVM (`cpu.bats` skips on Darwin because
`systemd-tmpfiles` is Linux-only).

- `just test` - shellcheck + all bats suites. Output must be pristine.
- `nix fmt` - format every Markdown file with deno fmt and every Nix file with
  nixfmt, through treefmt-nix. Entering the devshell installs the git hooks: a
  pre-commit hook refuses a commit whose staged files `nix fmt` would change (it
  reformats them; stage them again), and a pre-push hook runs gitleaks on the
  commits being pushed.
- `just check-pins` - verify the pinned base, hoprd image, builder and
  bootc-image-builder references still resolve; CI runs it before `just build`.
- `just update-pins` - move the base, builder and bootc-image-builder pins to
  the newest digest or immutable tag their tags offer, then check them; the
  hoprd image digest moves with its two binary hashes by hand. The diff goes in
  by PR.
- `just build` - build the image (`localhost/gvpn-exit-os:dev`); needs
  `GVPN_IMAGE_REPO` and `GVPN_COSIGN_PUB` (the public half of the key that signs
  the updates this image will accept).
- `just iso` - unattended installer ISO for hardware and Incus VMs: your SSH key
  for `devops`, plus the first-access tunnel for a managed device
  (`GVPN_BASTION`, `GVPN_SUPPORT_PORT`, `GVPN_ENROLL_KEY`,
  `GVPN_BASTION_KNOWN_HOSTS`: all four or none); `GVPN_INSTALL_DISK` defaults to
  `auto` (the installer picks the only internal disk and stops when there is not
  exactly one) or names the disk the kickstart wipes (`nvme0n1`, `sda`, `vda`).
  `just iso-console` builds it with no SSH key: `devops` gets an expired
  temporary console password instead.
- `just usb <device> [iso]` - write the built ISO, or the given one (a pulled
  `output/published-iso/install.iso`), to a whole USB disk after a typed
  confirmation; asks `sudo` and destroys that disk.
- `just vm-install` / `just vm-run` / `just vm-ssh` - QEMU rehearsal;
  installation deletes existing VM state.
- `just publish` - push the built image signed (`GVPN_COSIGN_KEY`, default
  `./cosign.key`) and move `canary` to it; it never moves `stable` and never
  re-points a version tag.
- `just push` - push the built image signed without moving a channel tag.
- `just promote <version> <channel>` - promote an existing version to canary or
  stable after verifying its signature against `GVPN_COSIGN_PUB`.
- `just recovery-build` / `just recovery-image` / `just recovery-usb` - build
  the recovery stick, pack it into one image to send, or write it to a stick
  ([runbook](docs/recovery.md)).
- `just incus-install [iso]` / `just incus-run` / `just incus-ssh` - install the
  ISO (built with `just iso` when none is given) into an Incus VM instead of
  hardware, boot it, and reach it; `incus-console` and `incus-destroy` cover the
  remaining steps ([runbook](docs/incus.md)). The VM is a production alternative
  to hardware (min. 8 vCPUs, 16 GiB RAM).
- `just pull-iso REF` - pull the published ISO into `output/published-iso/` and
  verify it against `GVPN_COSIGN_PUB`. The ISO lives in `GVPN_ISO_REPO`, or next
  to the image in `GVPN_IMAGE_REPO` when that is not set. CI builds it from the
  image and publishes it as a signed OCI artifact (`iso-<version>`) before it
  pushes the image: unmanaged, console-configured with no SSH key, install disk
  picked at install time. `just incus-install-published REF` pulls and installs
  it in one step, `just publish-iso` / `just push-iso` publish it by hand, and
  `just tag-iso VERSION` moves `iso-canary` after a promotion.
- `just test-integration unprovisioned|enroll|provision|provisioned|address|update` -
  checks against the running VM over SSH (`VM_SSH_KEY` selects the key). The VM
  ISO is built against the throwaway bastion `tests/integration/bastion.sh`.

Follow the [build runbook](docs/build.md) for inputs and sequencing. ISO boot
wipes the target disk. Publishing moves a shared channel; the update test also
writes a shared registry tag. Neither is a local-only validation step.

## Conventions

- Keep script paths and tunables overridable through env vars with device
  defaults (`GVPN_STATE_DIR`, `GVPN_NOW`, ...), so bats can run them against a
  sandbox with recording mocks on `PATH` (`tests/unit/helpers.bash`).
- Scripts that tests source guard dispatch with
  `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` so single functions can be called;
  everything else runs as a command.
- Image-owned config lives under `/usr` (`/usr/share/gvpn-exit`,
  `/usr/lib/...`); `/etc` only holds files that are device-specific or that a
  package expects there. Locally modified `/etc` files are preserved across
  bootc updates; do not rely on image changes replacing them.
- Every unit that must not run before provisioning carries
  `ConditionPathExists=/var/lib/gvpn-exit/identity/provisioned` itself;
  conditions do not propagate through `Requires=`.
- Everything that listens or forwards `Requires=gvpn-exit-firewall.service`.
- TDD: write the bats test first, watch it fail, then implement.
