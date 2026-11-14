# Move a device to another image repository

A device follows `<repo>:<channel>` of the repository its image was built for
(`GVPN_IMAGE_REPO`), and its `/etc/containers/policy.json` accepts signatures
for that repository only. Publishing to another repository therefore moves no
device, even when the images there are signed with the same key. This runbook
moves one device, over SSH, to a new repository signed with the key the device
already trusts: it adds that repository to the device's signature policy,
switches the tracked reference, and lets the device's own apply path take the
hoprd snapshot and reboot. Update mechanics are in
[architecture.md](architecture.md#updates).

**The image the device runs is not in the new repository, so the switch is also
an update.** The device boots whatever `<new repo>:<channel>` serves, and every
change between the two versions lands in one reboot. Read the migration notes of
each release in between before you start: a device that runs hoprd v4 comes back
with hoprd stopped until its [v4-to-v5 migration](hoprd-v5-migration.md), and a
device installed with the `devops` account comes back with it renamed to `gvpn`.
A rollback still works (the previous image stays on the device), but a rolled
back device tracks the old repository again
([rollback](#if-the-device-rolls-back)).

## Before you start

- The new repository serves the channel the device follows, published by
  `just publish`, `just promote` or the release workflows with `GVPN_IMAGE_REPO`
  set to the new repository. Images copied from the old repository with their
  signatures (`skopeo copy`, `crane copy`) do not work: their signatures name
  the old repository, and the policy's `matchRepository` refuses them.
- The new repository allows anonymous pulls
  ([deployment inputs](build.md#deployment-inputs)).
- SSH access as the administrator account (`gvpn`, or `devops` on a device
  installed from an earlier ISO), on the LAN or through the support tunnel.
- A time when the device may reboot: applying stops hoprd for the snapshot and
  interrupts VPN service and SSH.

On a workstation, check that the channel verifies against the device's key and
that its signature names the new repository:

```sh
NEW=registry.example.net/fleet/gvpn-exit-os   # the new repository, no tag
CH=stable                                     # the channel the device follows
cosign verify --key /secure/path/cosign.pub --insecure-ignore-tlog=true "$NEW:$CH" \
  | jq -r '.[].critical.identity["docker-reference"]'
```

Every printed reference must start with `$NEW:`.

## 1. Read the device's state

On the device:

```sh
sudo bootc status --format=json \
  | jq -r '.spec.image.image, .status.booted.image.version, .status.booted.image.imageDigest'
```

The first line is the tracked reference, for example
`old.registry.example/fleet/gvpn-exit-os:stable`. Set the variables from it:

```sh
OLD=old.registry.example/fleet/gvpn-exit-os   # the tracked reference without its tag
CH=stable                                     # its tag
NEW=registry.example.net/fleet/gvpn-exit-os
skopeo inspect --no-tags "docker://$NEW:$CH" \
  | jq -r '.Digest, .Labels["org.opencontainers.image.version"]'
```

The last command shows that the device reaches the new channel without
credentials, and which version and digest it will boot. Then check that the
running image has what the next steps use:

```sh
bootc --version                                       # 1.16.10 or later has switch --download-only
systemctl cat gvpn-exit-update-apply-now.service >/dev/null && echo apply-now ok
cat /etc/containers/registries.d/*.yaml               # use-sigstore-attachments under default-docker
```

If `use-sigstore-attachments` is set for the old registry only instead of under
`default-docker`, the device does not look up signatures in the new registry and
refuses every image there; set it for the new registry as well in a file of its
own (`man containers-registries.d`), which step 5 removes. If the apply unit is
missing, the running image cannot take the hoprd snapshot step 4 relies on: stop
here.

## 2. Trust the new repository

Copy the old repository's policy entry, which names the key and the
`matchRepository` rule, to the new repository:

```sh
jq --arg old "$OLD" --arg new "$NEW" '.transports.docker[$new] = .transports.docker[$old]' \
  /etc/containers/policy.json > /tmp/policy.json \
  && jq -e --arg new "$NEW" '.transports.docker[$new][0].keyPath' /tmp/policy.json \
  && sudo tee /etc/containers/policy.json < /tmp/policy.json > /dev/null
```

The second `jq` prints the key path, normally
`/etc/pki/containers/gvpn-exit-os.pub`; if it prints `null`, `$OLD` does not
match the policy's entry and nothing was written. The old entry stays, so the
device keeps its updates from the old repository if the switch fails or a later
boot rolls back. `tee` rewrites the file in place and keeps its mode and SELinux
label. The change is local to `/etc`, so every later deployment carries it until
step 5 resets it.

## 3. Stage the new image without applying it

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
nothing: the device keeps its image and still tracks `$OLD:$CH`. Check the
result:

```sh
sudo bootc status --format=json \
  | jq '.status.staged | {image: .image.image.image, digest: .image.imageDigest, downloadOnly}'
```

The staged deployment must show `$NEW:$CH`, the digest from step 1 and
`"downloadOnly": true` (`Download-only: yes` in `bootc status --verbose`). Do
not reboot while it is `false`: run the locked `bootc upgrade --download-only`
again first. Running `bootc switch` again does not change a staged deployment
that already tracks `$NEW:$CH`.

Staging now follows `$NEW:$CH`: the hourly run keeps the staged deployment
download-only, or stages a newer one the same way when the channel moves. A
reboot before step 4 discards it, and the device tracks `$OLD:$CH` again; repeat
step 3.

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
sudo bootc status                            # booted: $NEW:$CH; rollback: the old image
sudo gvpn-exit-status
sudo journalctl -b -u greenboot-healthcheck
```

Then reset the signature policy to the one the new image ships, which trusts the
new repository only, as on a device installed from it:

```sh
sudo cp /usr/etc/containers/policy.json /etc/containers/policy.json
sudo ostree admin config-diff | grep 'containers/'   # prints nothing
```

A `registries.d` file added in step 1 shows up there as `A`; delete it, since
the new image looks up signatures in every registry.

Until this reset, the device keeps the policy of step 2, and later image changes
to `policy.json` never reach it
([bootc keeps locally modified `/etc` files](architecture.md#configuration)).

If the device ran hoprd v4 before, `gvpn-exit-status` reports the v5 migration
as pending: run the [v4-to-v5 migration](hoprd-v5-migration.md).

## If the device rolls back

The old image does not need to be in any registry for a rollback: the previous
deployment stays on the device. When greenboot rejects the new image, the device
boots the old one again, data-guard restores the snapshot taken in step 4, and
the new digest is recorded as rejected. The device then tracks `$OLD:$CH` again,
with the policy of step 2, and its hourly staging follows the old repository as
long as that repository serves the channel.

To retry, publish a fixed image to `$NEW:$CH` and repeat steps 3 to 5: the apply
path refuses to apply a rejected digest. The old image leaves the device with
its next update after a successful switch, when the new image becomes the
rollback deployment; from then on the device can only go forward.
