# Publish an image to canary

Build, sign and publish an OS update for provisioned devices that track the
canary channel. **Publishing moves a shared tag: every device on canary can pick
up the update.** Coordinate with the channel's operators. Update mechanics are
in [architecture.md](architecture.md#updates).

**The first hoprd v5 update stops every v4 device's hoprd until it is
migrated.** hoprd.service is held stopped until the v5 provisioning file exists,
and the required boot check treats that as a pending migration rather than a red
boot. The device stays reachable, but its exit serves nothing until an operator
runs [`gvpn-exit-hoprd-migrate`](hoprd-v5-migration.md) on it. Do not move
`stable` to the v5 image until the fleet's old v4 Safes and channels are
migrated (or are scheduled to be).

## 1. Prepare the build host

You need:

- Nix and Docker daemon access, or root with Podman;
- push access to the registry, with sigstore attachment support, through the
  host's registry tools (for example `skopeo login registry.example.org`);
- the image-update key pair, **whose public key the target devices already
  have** at `/etc/pki/containers/gvpn-exit-os.pub` (it was `GVPN_COSIGN_PUB`
  when those images were built);
- reviewed, committed source whose version has not been published.

The devices pull `<repo>:<channel>` without credentials, so that repository must
allow anonymous pulls; a private registry is not supported today
([deployment inputs](build.md#deployment-inputs)).

```sh
export GVPN_IMAGE_REPO='registry.example.org/fleet/gvpn-exit-os'  # the repo devices track
export GVPN_COSIGN_KEY=/secure/path/cosign.key                    # default ./cosign.key
export GVPN_COSIGN_PUB=/secure/path/cosign.pub                    # defaults to ./keys/cosign.pub when that file exists
export GVPN_COSIGN_PASSPHRASE_FILE=/secure/path/cosign.passphrase # an empty file for a key without one
```

`GVPN_COSIGN_PASSPHRASE_FILE` is only needed where no terminal can be asked:
skopeo prompts for the passphrase when it is given no file, so a run without
that variable refuses before it signs anything when stdin is not a terminal.
Point it at a file holding the passphrase, or at an empty file for a key without
one.

If you have no pair yet, create one once. Publishing from a workstation keeps
the private half offline; the CI release workflow keeps it as a secret of its
`release` environment instead, which means whoever can run that workflow can
sign ([CI](build.md#ci)).

```sh
cosign generate-key-pair --output-key-prefix /secure/path/cosign
```

Every image you install has the public half baked in, so the pair is the update
identity of that fleet: losing the private half means those devices can only be
re-installed, and a different key is a new trust root
([roadmap](roadmap.md#release-process)).

Keep the private key out of Git and out of `keys/`, which is part of the image
build context. The repository ships no public key: a device trusts the key its
operator holds, so `GVPN_COSIGN_PUB` is a required input. `keys/cosign.pub` is
ignored by Git and is only the default location the tools look in when the
variable is unset and that file happens to exist.

## 2. Test, build and publish

```sh
nix develop -c just test
nix develop -c just channel=canary build publish
```

`tools/publish.sh` then:

1. exports the image from the builder's storage;
2. refuses a version tag (`git describe --tags --always --dirty`) that already
   exists, and one ending in `-dirty`: uncommitted source is not a release. Any
   lookup error other than `manifest unknown` aborts;
3. pushes `<repo>:<version>` with a sigstore signature made by skopeo;
4. verifies that digest with cosign against `GVPN_COSIGN_PUB`, without a
   transparency log;
5. only then points `:canary` at the same digest, which the signature covers.

It moves `canary` only. `stable` moves by promotion, and no other tag may be
re-pointed, because a version tag is published once.

Record the printed version and digest. Never delete or overwrite a published
version: commit or tag, rebuild and publish again. If verification fails, canary
is unchanged but the version tag may already exist; check the key and the
registry before retrying.

## Publish the installer ISO

The image workflow also builds the installer ISO for the same commit and pushes
it as a signed OCI artifact to a repository of its own, `GVPN_ISO_REPO`, so an
operator does not have to build one. The same ISO installs hardware and Incus
VMs. It is published under the image's immutable `<version>`; the ISO
repository's moving `canary` tag is moved separately with
`just tag-iso VERSION`, after the matching image version was promoted to canary.
From a workstation, after `just iso-console`:

```sh
export GVPN_ISO_REPO='registry.example.org/fleet/gvpn-exit-os-iso'
export GVPN_COSIGN_KEY=/secure/path/cosign.key
export GVPN_COSIGN_PUB=/secure/path/cosign.pub
export GVPN_COSIGN_PASSPHRASE_FILE=/secure/path/cosign.passphrase
nix develop -c just publish-iso       # <version> and canary in GVPN_ISO_REPO
nix develop -c just push-iso          # only <version>
```

`tools/publish-iso.sh` writes a checksum file over the ISO and its version and
target sidecars, signs that file with the same key as the image, verifies the
signature, pushes `install.iso`, the checksum file, its signature and the two
sidecars, and only then moves the ISO repository's `canary`. The version is the
one the ISO build recorded, the version label of the embedded image; an ISO
whose sidecars are missing or were written for another ISO is refused.
`GVPN_ISO` names another ISO file. A version is never overwritten, and
`push-iso` refuses a version that is already published from another build.
`just
tag-iso VERSION` pulls and verifies that version against `GVPN_COSIGN_PUB`
before it moves the ISO repository's `canary`. Pulling with
`just pull-iso <version>` (or `canary` after it was tagged) verifies the
signature and the checksums of the ISO, its version and its target before it
prints the local path; see
[first install](first-install.md#pull-the-published-iso) and
[what is verified](build.md#disk-images).

The published ISO is unmanaged, picks its install disk at install time and
carries no SSH key: the operator logs in on the console with the expired
temporary `devops` password, sets their own password and installs their public
key
([first access on the console](local-access.md#first-access-on-the-console)).
The publish refuses an ISO whose target sidecar is not `disk=auto`,
`enrollment=none` and `access=console`. Build a per-device ISO locally when it
needs bastion inputs or an installer key; a managed ISO is never published.

## Promotion to canary or stable

Images built and pushed on PR merge are stored at `<repo>:<version>` signed, but
do not move any channel tag (`canary` or `stable`).

To promote a version to a channel:

- Via GitHub Actions: run the **Promote Image** workflow manually
  (`workflow_dispatch`), specifying the `version` (commit short hash, version
  tag, or digest) and target `channel` (`canary` or `stable`).
- Via CLI:
  ```sh
  nix develop -c just promote VERSION CHANNEL
  ```

`tools/promote.sh` verifies the existing signature on the image against
`GVPN_COSIGN_PUB` and updates the channel tag in the registry with
`skopeo
copy --preserve-digests` without re-signing. A failed registry lookup
names the registry's own error, so an expired login does not look like a missing
tag.

## 3. Stage on the device

```sh
sudo bootc status                 # tracks <repo>:canary; note the booted digest
sudo gvpn-exit-status
systemctl list-timers 'gvpn-exit-update-*'
timedatectl
```

Staging runs hourly. To stage now without rebooting:

```sh
sudo systemctl start gvpn-exit-update-stage.service
sudo bootc status                 # staged digest = published digest
sudo journalctl -u gvpn-exit-update-stage.service -n 50
```

If nothing is staged, the journal shows why: the registry could not be reached,
the signature policy refused the image, or this device rejected the digest
before. Do not bypass these checks.

## 4. Apply

The apply timer runs at 03:00 plus up to 2 hours and reboots only between 03:00
and 05:59 device local time (UTC unless changed). Read the release's migration
notes first: a rollback restores the pre-update snapshot and
[loses later DB writes](architecture.md#rollback-of-application-data), including
tickets.

To apply now, outside the window:

```sh
sudo systemctl start gvpn-exit-update-apply-now.service
```

This reboots immediately, interrupting VPN service and SSH. It still snapshots
the DB, records ownership and refuses a rejected digest or a starting or
stopping hoprd, and it downloads nothing: stage and verify the digest first.
`gvpn-exit-update-apply.service` does the same but exits without rebooting
outside the window.

Never use a plain `bootc upgrade` followed by a reboot: it skips the snapshot
and ownership record, and data-guard then keeps hoprd down.

## 5. Verify after reboot

```sh
sudo bootc status                 # booted = published digest; rollback = previous
sudo gvpn-exit-status
sudo journalctl -b -u greenboot-healthcheck
sudo journalctl -b -1 -u gvpn-exit-update-apply.service   # or ...-apply-now.service
```

`-b -1` needs persistent journald logs. If the device rolled back, read
greenboot's journal before publishing again; the device skips that digest while
it is among its last 10 rejections. Saved public-address settings survive
updates. Neither greenboot nor `gvpn-exit-status` proves funded-node or client
acceptance ([acceptance gate](first-install.md#7-acceptance-gate)).
