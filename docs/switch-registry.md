# Move a device to another image repository or channel

Devices installed before the production repository existed follow the HOPR
Association repository. This runbook moves one such device, over SSH, to the
GnosisVPN production repository; its last section moves a device between the
`canary` and `stable` channels of its repository
([switch channel](#switch-between-canary-and-stable)):

| What                | Repository                                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------------------- |
| Old (`$OLD`)        | `europe-west3-docker.pkg.dev/hoprassociation/docker-images/gnosis-vpn-exit-os`                                |
| Production (`$NEW`) | `europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis-vpn-exit-os`                           |
| Channel (`$CH`)     | `canary`; the old repository has no `stable` tag                                                              |
| Key that signs both | the GnosisVPN image-update key, DER sha256 `0423195eca30b269171bf88515ea93659841e3b45b940e2a407ff921c70dcda1` |

A device accepts signatures for the repository its image was built for only
(`/etc/containers/policy.json`), so publishing to production moves no device,
even though both repositories are signed with the same key. The runbook adds
production to the device's signature policy, switches the tracked reference, and
lets the device's own apply path take the hoprd snapshot and reboot. Update
mechanics are in [architecture.md](architecture.md#updates).

**Which devices need it.** A device that tracks `$OLD:canary`. A device
installed from the published ISO, managed or unmanaged, already tracks
`$NEW:canary` (or `$NEW:stable`) and needs nothing. A device built locally with
another update key trusts neither repository's signatures and cannot be moved
with this runbook; install it again from the published ISO
([install-unmanaged.md](install-unmanaged.md#pull-the-published-iso)).

**Production does not serve the image the device runs, so the switch is also an
update.** The device boots whatever `$NEW:canary` serves, and every change
between the two versions lands in one reboot. A device that runs hoprd v4 comes
back with hoprd stopped until its [v4-to-v5 migration](hoprd-v5-migration.md),
and its `devops` account comes back renamed to `gvpn`. A rollback still works
(the previous image stays on the device), but a rolled back device tracks
`$OLD:canary` again ([rollback](#if-the-device-rolls-back)).

## Before you start

- SSH access as the administrator account (`devops` on a device installed from
  the old repository, `gvpn` on a later one), on the LAN or through the support
  tunnel.
- A time when the device may reboot: applying stops hoprd for the snapshot and
  interrupts VPN service and SSH.
- The GnosisVPN public key on the workstation, saved as `gnosisvpn-cosign.pub`
  ([the key](install-unmanaged.md#pull-the-published-iso)).

On the workstation, check that production `canary` verifies against that key and
that its signature names the production repository:

```sh
NEW=europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis-vpn-exit-os
CH=canary
cosign verify --key gnosisvpn-cosign.pub --insecure-ignore-tlog=true "$NEW:$CH" \
  | jq -r '.[].critical.identity["docker-reference"]'
skopeo inspect --no-tags "docker://$NEW:$CH" \
  | jq -r '.Digest, .Labels["org.opencontainers.image.version"]'
```

Every reference `cosign` prints must start with `$NEW:`. Note the digest and
version: the device must stage exactly this digest in step 3.

## 1. Read the device's state

On the device, set the variables, then check what it follows and that it trusts
the GnosisVPN key:

```sh
OLD=europe-west3-docker.pkg.dev/hoprassociation/docker-images/gnosis-vpn-exit-os
NEW=europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis-vpn-exit-os
CH=canary
sudo bootc status --format=json \
  | jq -r '.spec.image.image, .status.booted.image.version, .status.staged.image.image.image // "none staged"'
sudo openssl pkey -pubin -in /etc/pki/containers/gvpn-exit-os.pub -outform DER | sha256sum
sudo jq '.transports.docker | keys' /etc/containers/policy.json
```

The first line must be `$OLD:canary`; on `$NEW` the device needs nothing. The
key hash must be the one in the table above; with any other, stop: the device
refuses production images. The policy must list `$OLD`.

Then check that the device reaches production without credentials and that the
running image has what the next steps use:

```sh
skopeo inspect --no-tags "docker://$NEW:$CH" | jq -r '.Digest'   # the digest from the workstation
bootc --version                                       # 1.16.10 or later has switch --download-only
systemctl cat gvpn-exit-update-apply-now.service >/dev/null && echo apply-now ok
cat /etc/containers/registries.d/*.yaml               # use-sigstore-attachments under default-docker?
sudo gvpn-exit-status | grep -i hoprd                 # v4 means a migration after the switch
```

If the apply unit is missing, the running image cannot take the hoprd snapshot
step 4 relies on: stop here. If `use-sigstore-attachments` is set for `$OLD`
only instead of under `default-docker`, the device does not look up signatures
in production and refuses every image there; step 2 adds a lookup file for it.

## 2. Trust the production repository

Copy the old repository's policy entry, which names the key and the
`matchRepository` rule, to production:

```sh
jq --arg old "$OLD" --arg new "$NEW" '.transports.docker[$new] = .transports.docker[$old]' \
  /etc/containers/policy.json > /tmp/policy.json \
  && jq -e --arg new "$NEW" '.transports.docker[$new][0].keyPath' /tmp/policy.json \
  && sudo tee /etc/containers/policy.json < /tmp/policy.json > /dev/null
```

The second `jq` prints the key path, `/etc/pki/containers/gvpn-exit-os.pub`; if
it prints `null`, `$OLD` does not match the policy's entry and nothing was
written. The old entry stays, so the device keeps its updates from `$OLD` if the
switch fails or a later boot rolls back. `tee` rewrites the file in place and
keeps its mode and SELinux label. The change is local to `/etc`, so every later
deployment carries it until step 5 resets it.

Only when step 1 showed `use-sigstore-attachments` for `$OLD` alone, add the
signature lookup for production:

```sh
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "$NEW" \
  | sudo tee /etc/containers/registries.d/50-gvpn-switch.yaml > /dev/null
```

## 3. Stage the production image without applying it

```sh
sudo flock /run/gvpn-exit/update.lock bootc switch --download-only "$NEW:$CH"
```

The lock is the one the staging and apply services hold, so no timer stages or
applies in the middle of the switch. bootc 1.12 to 1.16.9 has no
`switch --download-only`; on such a device, switch and then mark the staged
deployment download-only in the same locked run (`bootc upgrade` fetches the
staged deployment's reference and locks it when the digest is unchanged):

```sh
sudo flock /run/gvpn-exit/update.lock sh -c "bootc switch '$NEW:$CH' && bootc upgrade --download-only"
```

Between those two commands the staged deployment would apply at any reboot,
without the hoprd snapshot.

A refused signature or an unreachable registry fails the switch and stages
nothing: the device keeps its image and still tracks `$OLD:canary`. Check the
result:

```sh
sudo bootc status --format=json \
  | jq '.status.staged | {image: .image.image.image, digest: .image.imageDigest, downloadOnly}'
```

The staged deployment must show `$NEW:canary`, the digest from the workstation
check and `"downloadOnly": true` (`Download-only: yes` in
`bootc status --verbose`). Do not reboot while it is `false`: run the locked
`bootc upgrade --download-only` again first. Running `bootc switch` again does
not change a staged deployment that already tracks `$NEW:canary`.

Staging now follows `$NEW:canary`: the hourly run keeps the staged deployment
download-only, or stages a newer one the same way when the channel moves. A
reboot before step 4 discards it, and the device tracks `$OLD:canary` again;
repeat step 3.

## 4. Apply

```sh
sudo systemctl start gvpn-exit-update-apply-now.service
```

This is the same path as every update, run by the image the device boots now: it
stops hoprd, snapshots its database for the running image, releases the staged
deployment, records data ownership for data-guard and reboots. Without it,
`gvpn-exit-update-apply.timer` applies the staged deployment in the next
maintenance window (03:00-05:59 device local time), if the device does not
reboot before. Never use `bootc switch --apply`, or a plain `bootc switch` and a
reboot: they skip the snapshot and the ownership record, and data-guard then
keeps hoprd down.

## 5. Verify and reset the policy

Log in again after the reboot, as `gvpn` (the first boot renames a `devops`
account and keeps its keys):

```sh
sudo bootc status                            # booted: $NEW:canary; rollback: the old image
sudo gvpn-exit-status
sudo journalctl -b -u greenboot-healthcheck
```

Then reset the signature policy to the one the production image ships, which
trusts production only, as on a device installed from it:

```sh
sudo cp /usr/etc/containers/policy.json /etc/containers/policy.json
sudo jq '.transports.docker | keys' /etc/containers/policy.json   # $NEW only
sudo rm -f /etc/containers/registries.d/50-gvpn-switch.yaml
sudo ostree admin config-diff | grep 'containers/'                # prints nothing
```

Until this reset, the device keeps the policy of step 2, and later image changes
to `policy.json` never reach it
([bootc keeps locally modified `/etc` files](architecture.md#configuration)).

If the device ran hoprd v4 before, `gvpn-exit-status` reports the v5 migration
as pending: run the [v4-to-v5 migration](hoprd-v5-migration.md).

## If the device rolls back

The old image does not need to be in any registry for a rollback: the previous
deployment stays on the device. When greenboot rejects the production image, the
device boots the old one again, data-guard restores the snapshot taken in step
4, and the production digest is recorded as rejected. The device then tracks
`$OLD:canary` again, with the policy of step 2, and its hourly staging follows
the old repository as long as that repository serves `canary`.

To retry, publish a fixed image to production `canary` and repeat steps 3 to 5:
the apply path refuses to apply a rejected digest. The old image leaves the
device with its next update after a successful switch, when the production image
becomes the rollback deployment; from then on the device can only go forward.

## Switch between canary and stable

A device follows one channel tag of its repository, `canary` or `stable`
([promotion](publish-image.md#promotion-to-canary-or-stable)). Moving it to the
other tag of the same repository needs no change to its signature policy: both
tags are signed with the same key for the same repository. It is the
`bootc switch` of step 3 and the apply of step 4. Staging follows the reference
bootc tracks, so every later update comes from the new channel.

Switch when the new channel serves the version the device runs or a newer one.
There is no minimum-version floor ([updates](architecture.md#updates)): a
channel that serves an older image is a downgrade, and the older hoprd then runs
on a database a newer one wrote. When both tags point at the same digest, only
the tracked tag changes and the device reboots into the image it runs.

On the device, set the repository and the channel to move to, then compare what
the device runs with what that channel serves:

```sh
REPO=europe-west3-docker.pkg.dev/gnosisvpn-production/docker-images/gnosis-vpn-exit-os
CH=stable
sudo bootc status --format=json \
  | jq -r '.spec.image.image, .status.booted.image.imageDigest, .status.booted.image.version'
skopeo inspect --no-tags "docker://$REPO:$CH" | jq -r '.Digest, .Labels["org.opencontainers.image.version"]'
```

The first line, the reference the device tracks, must be the other channel of
`$REPO`; a device on another repository needs steps 1 to 5 first. Stage the
channel without applying it, check the staged deployment, then apply it:

```sh
sudo flock /run/gvpn-exit/update.lock bootc switch --download-only "$REPO:$CH"
sudo bootc status --format=json \
  | jq '.status.staged | {image: .image.image.image, digest: .image.imageDigest, downloadOnly}'
sudo systemctl start gvpn-exit-update-apply-now.service
```

Apply only when the staged deployment shows `$REPO:$CH`, the digest the channel
serves and `"downloadOnly": true`. bootc 1.12 to 1.16.9 needs the two-command
variant of step 3. Step 4 holds as written: without the apply unit, the next
maintenance window applies the switch, and a reboot before then discards it, so
the device follows its old channel again. `bootc switch --apply`, or a plain
`bootc switch` and a reboot, skips the hoprd snapshot and the ownership record.

After the reboot, `sudo bootc status` shows `$REPO:$CH` as booted and
`sudo gvpn-exit-status` reports it as `image`. When greenboot rejects the boot,
the device rolls back to its previous deployment, which tracks the old channel
([if the device rolls back](#if-the-device-rolls-back)).
