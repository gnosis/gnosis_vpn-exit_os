# Roadmap and open items

Unbuilt features, acceptance gaps and open decisions. Current behaviour is in
[architecture.md](architecture.md); nothing here describes deployed devices.

## Pending decisions in the code

| Where                                    | Decision                                                                                                                                                                                                                                                                                                                          |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gvpn-exit-status`, `severity_for`       | Which soft probe failures FAIL instead of WARN. Today all WARN, including a Blokli URL mismatch and announced-address drift.                                                                                                                                                                                                      |
| `hoprd.cfg.yaml`, `iptables.rules`       | With the hoprd team: stay unannounced and outbound-only, or announce with an INPUT allowance for 9091 plus a UPnP/NAT-PMP mapping. Today the device announces an address its own firewall makes undialable and only reports drift.                                                                                                |
| `red.d/10-gvpn-record-rejection.sh`      | Whether a red boot of an already-blessed image should reject its digest. Today every red boot does, which also blocks a later emergency revert to that digest, and no command lists or clears rejections. Options: reject only on the first boot of a newly applied digest; add an operator command to list and clear rejections. |
| `capacity.sh`, `resolve_capacity`        | Below the 30 Mbit/s supported floor the device serves one client best effort instead of refusing service, and a failed measurement keeps serving the last good sample indefinitely. Decide whether such a device should be reported as out of contract (heartbeat field, status FAIL) or drained from the fleet.                  |
| `exit.env`, `GVPN_BLOCKLIST_FEEDS`       | The feed is trusted by URL on a branch that moves upstream and is not authenticated. Mirror it per deployment, or keep it: the parser, the entry-count band and the coverage ceiling bound what a poisoned feed can do ([architecture](architecture.md#traffic-shaping-and-blocklist)).                                           |
| `support-window.sh`, `gvpn-exit-support` | The support window is a root-written timestamp, not a signed authorization ([architecture](architecture.md#what-the-support-window-trusts)). Decide whether signed, revocable support authorization replaces it; today the bound is the 90-day maximum and the fact that whoever holds the bastion is already trusted.            |

## Release process

- CI: Workflows run `just test`, `just lint`, `just build` and
  `just
  iso-console-only` on every PR. On PR merged into `main`, the image is
  built and pushed to the remote repository signed, without moving channel tags
  (`just
  push`), and the installer ISO is published as a signed OCI artifact
  under the image's `<version>` in its own repository; its channel tag moves
  with `just tag-iso VERSION` after the image is promoted. A manual workflow
  (`just promote VERSION CHANNEL`) promotes a verified version to `canary` or
  `stable`. Release CI will add QEMU integration and snapshot/restore
  acceptance.
- Release gate: `publish.sh` and `publish-iso.sh` refuse `-dirty` versions, but
  `git describe --dirty` ignores untracked files that the build context
  includes. Refuse those too, add `org.opencontainers.image.revision` and
  `source` labels, and define a tag convention; versions are currently short
  hashes.
- Verified first install: device ISOs are built from local source and installed
  unsigned from local storage, so day-0 installs never run the published image.
  CI builds and publishes the installer ISO, but that ISO still installs the
  locally built image in its bootc-image-builder disk. The published ISO is
  console-configured and carries no SSH key. Build both from the published
  digest and evaluate `bootc install to-disk --enforce-container-sigpolicy`.
- Signing-key custody and rotation (KMS or hardware) compatible with the device
  verifier. Devices trust the key their image was built with
  (`GVPN_COSIGN_PUB`); a rotation must ship in an update signed with the
  currently trusted key, and `policy.json` can trust both keys during the
  transition. Publishing from a workstation keeps the private half offline; the
  CI release workflow holds it as a secret of its `release` environment, so
  whoever can run that workflow can sign ([CI](build.md#ci)).
- Automated pin-bump PRs for `image/versions.env`. `just check-pins` (CI, before
  the build) turns a dead pin into a named failure and `just update-pins` bumps
  every pin, so the gap is a scheduled job that runs it and opens the PR.
- Canary soak of at least 7 days with green heartbeats and no rejections, then
  manual promotion that verifies the soaked digest and copies it to stable
  without re-signing. An emergency channel re-pointing procedure.
- Fedora 44 reaches end of life in mid-2027. Rehearse a major-version rebase
  through canary, including a forced rollback, well before.

## Tests not yet built

Build an isolated multi-VM harness with its own registry and bastion; the
`update` phase currently uses the shared registry.

| Acceptance test                   | Required result                                                                                                                                                                                                                      |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Packet isolation, empty blocklist | A VPN client reaches an internet fixture (`203.0.113.10`) but not the LAN (`192.168.77.10`) or device SSH; LAN SSH still works                                                                                                       |
| Packet isolation, hairpin         | With the device's public address known from a router fixture, a session to that address is dropped before MASQUERADE: neither the router nor a hairpinned LAN host sees it                                                           |
| Blocklist                         | Fixture `203.0.113.0/24` blocks that traffic                                                                                                                                                                                         |
| Blocklist poison                  | A feed containing `0.0.0.0/1` is rejected while its ordinary entries still swap in                                                                                                                                                   |
| Shaping                           | Client throughput within 10% of `GVPN_PEER_CEIL_KBIT`                                                                                                                                                                                |
| Capacity                          | On a shaped uplink, a boot yields the expected peer slots and one more client than slots is refused; a changed link after reboot changes the pool                                                                                    |
| Real-data rollback                | A failing required check forces the old image; snapshot restored, rejected writes absent, rejected DB kept, red then green heartbeat                                                                                                 |
| Red-boot behaviour                | Force a red boot without an update and watch `grub2-editenv list` across reboots: greenboot-rs reboots after every red boot, so GRUB's boot counter must end the loop on an Anaconda install; document the result in architecture.md |
| Rollback trigger                  | With a rollback deployment, a download-only staged update plus an unprepared reboot leaves `rollbackQueued` false and no fallback verdict (the `update` phase does this once a second digest is published)                           |
| Sandboxed services                | `provisioned`, `address` and `update` pass: wg-quick, iptables-nft, ipset and tc work in gnosisvpn-server's sandbox, hoprd writes only its declared directories, both tunnels reach the bastion as dynamic users                     |
| Server readiness                  | Time from `gnosisvpn-server` active to an answering API and an existing `wggvpn` on an offline boot                                                                                                                                  |
| Interrupted update/restore        | Power loss across snapshot replacement, deployment release, ownership writes and restore; define recovery                                                                                                                            |
| Signatures                        | Unsigned and wrong-key updates rejected, enforced unsigned installs rejected, a promoted stable digest accepted                                                                                                                      |
| Maintenance window                | No reboot at 14:00 or from an out-of-window catch-up; apply at 03:30                                                                                                                                                                 |
| Rejections                        | A rejected digest is skipped, a different one accepted                                                                                                                                                                               |
| Support lifecycle                 | An expired window stays closed; an active tunnel closes within the polling interval; reconnect after a bastion restart; wrong reverse-port authorization rejected                                                                    |
| NAT report and connectivity       | UPnP status from a router VM is read-only; bastion and client sessions work through double NAT and CGNAT-like routing                                                                                                                |
| Offline boot                      | Provisioned local health passes and the boot is blessed without network                                                                                                                                                              |

Some of these have mocked unit coverage or partial integration checks; none
passes end to end yet.

## Fleet and onboarding

- Production bastion and device register, and a host-key rotation that installs
  the next pinned key before retiring the old one (outside this repository).
- Fleet backend: verify heartbeat signatures against the support key in the
  provisioning record (`ssh-keygen -Y verify -n gvpn-exit-heartbeat`), decide
  how to treat `signature: null` from a provisioned device, alert after more
  than 6 hours of silence. The heartbeat has no peer count, because hoprd's API
  token exists only in hoprd's credential directory.
- Operator access: a key-configured ISO embeds one devops key, the published ISO
  starts console-only and each operator adds their own, and sshd trusts no user
  CA, so revoking an operator touches every device. Ship an SSH CA
  (`TrustedUserCAKeys`) in the image so access rotates with signed updates.
- Record the device's SSH host-key fingerprints and the TPM EK hash in the
  provisioning record, so operators can verify the host key as the runbook asks.
- TPM loss: a TPM clear, fTPM reset or board replacement loses the sealed
  identity. Write a re-identity runbook (new identity, Safe module, HOPR
  listing) and decide between re-provisioning and escrow.
- [Acceptance gate](first-install.md#7-acceptance-gate) tooling: bench
  acceptance covering greenboot, Blokli sync, server ping, funded on-chain
  address, a client session and a blocklist smoke test, including an uplink
  without public address or UPnP. Write the verifier in this repository.
- Signed support-window authorization instead of a root-written timestamp.
- Release notes describing DB migrations, the v4-to-v5 Safe/channel migration
  and the accepted rollback ticket loss.

## Device gaps

- Server readiness: `20-gvpn-server.sh` and `40-gvpn-shaping.sh` now wait 60 s
  (`wait_for` in `checks.sh`) instead of probing once, but the real startup
  timings were not measured on hardware; a server that needs longer still fails
  the boot.
- Blocklist feeds are trusted by URL and refreshed from a moving branch. The
  entry-count and coverage checks bound a poisoned feed; mirror the feed and pin
  it per release for a supply chain that does not depend on the upstream branch.
- SELinux: confined domains for the custom services and persistent data labels;
  enforcing mode and the integration AVC check do not prove confinement.
- Private registry: devices pull their channel tag without credentials, so the
  image repository must allow anonymous pulls. A registry that requires a login
  needs a pull credential on every device and a way to rotate it; neither is
  implemented ([deployment inputs](build.md#deployment-inputs)).
- netdata: authenticated hoprd metrics and a go.d WireGuard job.
- Evaluate two-server STUN discovery next to the HTTPS and router observations;
  NAT classification still needs real client acceptance.
- Hardware ISO acceptance on both models: deployment `/etc` enrollment files,
  modes, SELinux labels, first-boot tunnel and the pinned disk layout with `/`
  spanning the disk.
- Explicit persistent journald storage with a size cap; base defaults apply
  today.

## Upstream questions

- greenboot: `set-rollback-trigger` should ignore download-only
  (finalization-locked) deployments; `rollback-trigger.sh` works around it.
- hoprd: password-from-file support, which would remove `hoprd-run.sh`.
- Pinned hoprd: confirm funded announcement after initialization and refresh,
  and the semantics of `/healthyz`. If clients need dialable ingress, design
  firewall and NAT traversal separately.
- Pinned gnosis_vpn-server: confirm writes to its tmpfs WireGuard configuration
  and the serve and config options it takes.
- Record the firmware menu paths for both models, including Always On.

## Documentation

- Fleet operations: channel recovery, heartbeats, support, rollback loss.
- Bench checklist through the acceptance gate.
- Threat model for isolation, credentials and updates. The support window's is
  in [architecture](architecture.md#what-the-support-window-trusts).
- Site quick-start card, once connectivity requirements are verified.

## Housekeeping

- `just test` runs shellcheck twice: the `lint` recipe and
  `tests/unit/lint.bats`, which is deliberate (the suite calls the recipe) and
  costs a few seconds.
- No `just` recipe for `tools/vm.sh run-headless`; the VM harness does not use
  the `qcow2` output.

## Phase 2

- Secure Boot with custom keys; verify each model's enrollment state.
- TPM2-bound LUKS root and an installation flow for it.
- LAN status page for the site's own staff.
- Optional netdata drop-in binding the LAN address (off by default).
- Minimum-version freeze check against a published floor. Blocked on an ordered
  version scheme: an image version is `git describe --tags --always` output, so
  it can be a short commit hash and nothing can compare two of them. Define the
  tag convention under [Release process](#release-process) first; until then a
  re-pointed channel can only be refused by the signature, not by age.
- Remove the bundled hoprd v4 binary and the v4 cleanup helper once the fleet
  has migrated ([migration runbook](hoprd-v5-migration.md)).
