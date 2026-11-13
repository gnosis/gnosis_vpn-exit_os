---
marp: true
title: ExitOS developer onboarding
paginate: true
size: 16:9
style: |
  section {
    font-size: 24px;
    padding: 50px 64px;
  }
  section h1 { color: #133e7c; }
  section h2 { color: #133e7c; margin-bottom: 0.4em; }
  section pre { font-size: 17px; line-height: 1.3; }
  section table { font-size: 19px; }
  section.lead { text-align: left; justify-content: center; }
  section.lead h1 { font-size: 64px; }
  section.small { font-size: 20px; }
  section.small pre { font-size: 15px; }
  section.small table { font-size: 17px; }
  .warn { color: #b3261e; font-weight: bold; }
---

<!-- _class: lead -->
<!-- _paginate: false -->

# Gnosis VPN ExitOS

### Developer onboarding

The exit-node appliance OS for the Beelink SER8 and GEEKOM A8

<!--
Speaker notes live in HTML comments like this one. Marp shows them in
presenter view (`--preview` or the VS Code extension).
-->

---

## What ExitOS is

A **Fedora IoT image in bootc mode** that turns a mini PC into a GnosisVPN exit node.

- Runs **`hoprd`** (HOPR mixnet node) and **`gnosis_vpn-server`** (WireGuard exit)
- Isolates VPN clients from private ranges and the device's own LAN
- Sizes per-peer **traffic shaping** from a boot-time uplink measurement
- Drops traffic to and from an **IP blocklist** (FireHOL level1)
- Seals credentials into the **TPM**
- Pulls **signed image updates** and **rolls back** on a red boot (greenboot)

The device is an appliance: no packages installed by hand, no config edited by hand.
Every behaviour change ships as a new image.

Out of scope for this repo: the support **bastion**. The **fleet backend** is not implemented, part of the roadmap.

---

## The two paths through a device

```text
GnosisVPN client -> HOPR session -> hoprd
                                    | session allow-list only
                                    +-> 172.30.0.1:8000   gnosis_vpn-server API
                                    +-> 172.30.0.1:51820  WireGuard (wggvpn)
                                                          |
                                         isolation, blocklist, shaping
                                                          |
                                                MASQUERADE -> lan0

Operator -> bastion loopback port -> reverse SSH tunnel -> device sshd -> devops (sudo)
```

- `172.30.0.1` is the client's built-in session target; it sits on `lo`, so no LAN route.
- The device only dials **out**: no router port mapping, no inbound p2p.
- Operators reach it through a **reverse tunnel** to the bastion (optional, chosen at install), or LAN SSH from RFC1918.

<!--
Point out that the "inbound" exit traffic arrives inside HOPR sessions that
hoprd itself opened outbound. Nothing on the LAN side needs to be reachable.
-->

---

## Why bootc / image mode matters for you

| Location | Behaviour | Rule of thumb |
|---|---|---|
| `/usr` | Read-only, replaced by every update | Image-owned config and scripts go here |
| `/etc` | **Three-way merged**: locally modified files survive updates | Only device-specific files or files a package expects there |
| `/var` | **Shared by all deployments**, never rolled back | All state; needs its own rollback story |

Consequences you will meet in code:

- Changing a default? Edit `/usr/share/gvpn-exit/...`, not `/etc`. An `/etc` change may never reach a device.
- An image rollback does **not** roll back the hoprd DB → `data-guard` and DB snapshots exist.
- Updates are whole images: `bootc upgrade`, signature-checked, with a fallback deployment.

---

## Repository map

| Path | What |
|---|---|
| `image/Containerfile` | The OS image; pins arrive as build args from `image/versions.env` |
| `image/versions.env` | Base digest, hoprd / hopli / server versions + sha256, netdata. **Bump by PR only** |
| `image/rootfs/` | Copied into the image: units, drop-ins, scripts, configs |
| `image/rootfs/usr/libexec/gvpn-exit/` | Bash runtime; `lib.sh`, `checks.sh`, `public-ip.sh` are sourced helpers |
| `image/rootfs/usr/bin/` | Operator CLIs: `gvpn-exit-provision`, `-support`, `-status`, `-hoprd-address`, `-hoprd-migrate` |
| `image/rootfs/usr/lib/greenboot/` | Boot health: `required.d` can roll back, `wanted.d` only logs |
| `image/build/`, `image/bib/` | Build-time helpers; bootc-image-builder configs (ISO, qcow2) |
| `keys/` | **Public keys only** (release keys, netdata repo); the image-update key is an operator input (`GVPN_COSIGN_PUB`) |
| `tools/` | Builder, disk builds, publish/promote, QEMU and Incus VM harnesses, recovery stick |
| `tests/unit/`, `tests/integration/` | bats suites with mocks; SSH checks against a real VM |
| `docs/` | `architecture`, `build`, `roadmap`, runbooks |

---

## Your dev loop

Everything runs inside the Nix devshell through `just`:

```sh
nix develop -c just test          # shellcheck + every bats suite; must be pristine
nix develop -c just lint          # shellcheck only (includes tests/integration/)
nix develop -c just check-pins    # do the pinned image references still resolve?
```

| Host | What works |
|---|---|
| `aarch64-darwin` | Unit tests, lint, `check-pins`, `promote` (GNU userland from the devshell). `cpu.bats` skips. |
| `x86_64-linux` | All of the above plus `build`, `iso`, `qcow2`, `usb`, `publish`, `push`, the QEMU harness and the Incus recipes (host Incus) |

Image builds go through `tools/builder.sh`: rootful Podman, or Podman inside a privileged Docker container.
Every build needs `GVPN_IMAGE_REPO` (it scopes the image's signature policy).

All artifacts land in the git-ignored `output/`.

---

## From source to device

```text
image/versions.env ─┐
keys/*.asc ─────────┼─► Containerfile ─► localhost/gvpn-exit-os:dev ─┬─► just iso   ─► USB ─► NVMe
image/rootfs/ ──────┘    (gpgv-verified    (smoke tests,              ├─► just qcow2
                          releases)         bootc container lint)     └─► just push / publish
                                                                            │  cosign-signed
                                                                            ▼
                                                     <GVPN_IMAGE_REPO>:<version>
                                                                            │  just promote
                                                                            ▼
                                                           :canary ──► :stable ──► devices pull
```

- hoprd v4, hopli and gnosis_vpn-server: sha256-pinned **and** GPG-verified against `keys/`.
  hoprd v5 comes from the digest-pinned PIX-enabled OCI image, its binaries sha256-checked.
- Base image and bootc-image-builder are digest-pinned; `just update-pins` moves them by PR.
- Devices accept only images signed by the key their image was built with
  (`GVPN_COSIGN_PUB`, `/etc/containers/policy.json`).
- Other RPMs and the blocklist snapshot come from live sources: builds are **not** byte-reproducible.

---

## Device lifecycle

```text
 ISO boot ──► unprovisioned ──► gvpn-exit-provision identity ──► (Safe + module funded
 (wipes disk)   firewall, sshd,       TPM-sealed keys,              elsewhere; support key
                enroll-tunnel         prints address + peer id      admitted on bastion)
                                                                          │
                ┌─────────────────────────────────────────────────────────┘
                ▼
      gvpn-exit-provision finalize ──► reboot ──► provisioned
      --safe-address --module-address    writes        hoprd, VPN server, shaping,
      --blokli-url --location            marker,       support tunnel, updates,
                                         deletes       heartbeat, netprobe ...
                                         enroll.key
```

The **provisioning gate** is one file: `/var/lib/gvpn-exit/identity/provisioned`.

Every unit that must not run before provisioning carries
`ConditionPathExists=/var/lib/gvpn-exit/identity/provisioned` **itself**, because conditions do not propagate through `Requires=`.
`tests/unit/units.bats` enforces this.

---

## Credentials

Sealed with `systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=` into `/var/lib/gvpn-exit/creds/`.

| Credential | Delivered via `LoadCredentialEncrypted=` to |
|---|---|
| `hopr.id` | `hoprd-run.sh`, which copies it to `/run/hoprd/hopr-v5.id` for hoprd |
| `hoprd.password`, `hoprd.api-token` | `hoprd-run.sh`, which exports them for hoprd |
| `wg.key` | `render-wg-conf.sh` → `/run/gnosisvpn-server/wggvpn.conf` (0600) |
| `support.key` | Support tunnel and heartbeat signing |

Know the limits:

- Only **this TPM** can decrypt; no PCR policy, so firmware and OS updates leave the credentials readable.
- Root can read them. Sealing is **not** disk encryption (Secure Boot + LUKS are phase 2).
- Losing the TPM (clear, fTPM reset, board swap) loses the identity.

---

## Network and firewall

- NIC is renamed to **`lan0`**; DHCP via NetworkManager. IPv6 disabled, ip6tables drops all.
- `gvpn-exit-firewall.service` loads static rules **before** the network is up:
  INPUT/FORWARD default **DROP**; SSH only from RFC1918 on `lan0`; no inbound p2p port.
- Traffic from `wggvpn` first hits **`GVPN_PRIVATE`**: drops 10/8, 172.16/12, 192.168/16,
  100.64/10, 169.254/16, 127/8, 0/8, 224/3 and the **`gvpn-self`** set (the device's own public IPs).
- `wg-hooks.sh up` adds dynamic rules **guards first**: blocklist, second private jump,
  TCP MSS clamp, shaping, then MASQUERADE + uplink ACCEPT at the tail. `down` reverses.

Convention: **everything that listens or forwards `Requires=gvpn-exit-firewall.service`.**

<!--
The MSS clamp is worth a minute: without it TCP origins that size segments
from a larger MTU stall after the handshake. See architecture.md.
-->

---

## Capacity and shaping

Capacity is **measured, not assumed**. `gvpn-exit-capacity.service` loads the link with parallel curl
transfers to Cloudflare's speed test endpoints before the VPN server on every provisioned boot and caches the sample in `state/capacity.env`.

| Knob | Formula | 200 Mbit/s link |
|---|---|---|
| aggregate | ⌊min(down, up) / 4⌋ | 50 Mbit/s |
| peer slots | ⌊aggregate / 5 Mbit/s⌋, ≥ 1 | 10 clients |
| per-peer ceiling | min(10 Mbit/s, aggregate) | 10 Mbit/s |
| per-peer guarantee | min(ceiling, aggregate / slots) | 5 Mbit/s |

- HTB + fq_codel: download on `wggvpn` egress, upload via `ifb-gvpn`. `lan0` itself is unshaped.
- Best effort: a failed probe, or one below 1 Mbit/s, keeps the last sample; no sample → assume the 30 Mbit/s floor.
- A pin in `/etc/gvpn-exit/exit.env` always wins over the measurement.
- Changing pool or rates needs a server restart, which **drops every client**.

---

## Blocklist

- FireHOL level1 in ipset `gvpn-blocklist`; `wg-hooks.sh` drops forwarded traffic both ways.
- Seeded from a snapshot taken at image build; refreshed 03:00 and 15:00 (+ up to 1 h).
- **Fails open**: the set is swapped atomically only if every feed downloaded and the list
  has 1000 – 131072 entries. Otherwise the last good list stays and metrics report it.
- The parser drops prefixes shorter than /8 (outside 224/3): a poisoned `0.0.0.0/1` cannot
  blackhole every session.
- Private-range isolation does **not** depend on the feed.

---

## Boot health (greenboot)

3 boot attempts, 24 h watchdog grace. Appliance checks skip on unprovisioned devices.

| Class | Examples | On failure |
|---|---|---|
| **Required** (`required.d`) | Firewall, data-guard, blocklist load, VPN server + API ping, `wggvpn`, isolation rules, IPv6 policy, HTB roots, sshd, netdata, node_exporter | **Red boot → can roll back** |
| Required while Blokli answers | hoprd active within 180 s and stable 60 s more | Red boot |
| **Wanted** (`wanted.d`) | Default route + DNS, Blokli, hoprd `/healthyz`, blocklist size | Logged only |

- An **offline device boots green** if its local software is healthy. Green ≠ clients work.
- Green hooks: heartbeat + prune old DB snapshots. Red hook: record digest as **rejected**.
- Putting a connectivity check in `required.d` would roll back devices for a flaky ISP. Don't.

---

## Updates

```text
 stage timer (hourly)            apply timer (03:00 + ≤2 h)              reboot
 bootc upgrade --download-only ─► window 03:00–05:59? not rejected? ─► snapshot DB ─► new image
 skip rejected digests            hoprd not starting/stopping?          write data-owner
```

- Devices track `<GVPN_IMAGE_REPO>:canary` or `:stable`; `policy.json` rejects unsigned images.
- Stock `bootc-fetch-apply-updates`, `rpm-ostree-countme`, `fwupd-refresh` timers are masked.
- A download-only deployment is **never** finalized by an ordinary reboot.
  `rollback-trigger.sh` keeps greenboot from arming a rollback for it.
- Stage and apply serialize on `/run/gvpn-exit/update.lock`.
- Operator shortcut: `systemctl start gvpn-exit-update-apply-now.service` (skips the window only).

<span class="warn">Never run a plain `bootc upgrade` + reboot on a device: without the snapshot and
ownership record, data-guard keeps hoprd down.</span>

---

## Rolling back application data

`/var` is shared across deployments, and a DB migration can make the new hoprd DB
unreadable for the old hoprd. So `update-apply.sh`:

1. stops hoprd, reflink-copies the DB to `/var/lib/hoprd-v5.snapshots/<current digest>`
2. releases the staged deployment (`bootc upgrade --from-downloaded`)
3. writes `data-owner-previous=<current>`, `data-owner=<staged>`, syncs, reboots

On every boot `data-guard.sh` compares the booted digest:

| Booted digest equals | Action |
|---|---|
| `data-owner` | Pass |
| `data-owner-previous` | Rollback: live DB → `hoprd-v5.rejected-<epoch>`, restore snapshot |
| anything else / snapshot missing | Fail → hoprd stays down |

**Accepted loss:** unredeemed tickets written after the snapshot. Not crash-safe across steps.

---

## Operator access and support

- **sshd**: only `devops`, only keys. Root and devops passwords are locked, except on a console-configured ISO (temporary console password, expired on first login; the console stays a way in until `sudo passwd -l devops`).
- **`enroll-tunnel.service`**: installer key, unprovisioned devices only.
- **`support-tunnel.service`**: TPM-sealed support key, only while `state/support-until`
  is in the future **and** the clock is NTP-synced. Re-checked every 5 minutes.
- `sudo gvpn-exit-support extend <1-90> | close | status` manages the window.
- The bastion must pin each key to its own reverse port (`permitlisten`); see
  `tests/integration/bastion.sh`.
- **Recovery stick** (`docs/recovery.md`): a UKI that adds operator keys and a
  `recovery-request` marker; the device opens the window once its clock is trusted.

---

## Observability

| Tool | Where | What |
|---|---|---|
| `sudo gvpn-exit-status` | On device (MOTD points to it) | Provisioning, Blokli, firewall, hoprd, WG, reachability, CPU; exits 1 on FAIL |
| node_exporter | `127.0.0.1:9100` | systemd + textfile metrics (blocklist, hoprd restarts) |
| netdata | `127.0.0.1:19999` | Reach with an SSH local forward |
| Heartbeat | POST to `GVPN_FLEET_URL` (fleet backend: not implemented, part of the roadmap) | Image, boot verdict, services, reachability, rejected digests; SSH-signed by the support key |
| `netprobe.sh` | `state/reachability.json` every 15 min | Observed IPv4, router's view (UPnP / NAT-PMP, read-only), NAT label |

- `hoprd-health.sh`: 3 failed `/healthyz` after a 15-min grace → `try-restart hoprd`.
- `hoprd-preventive-restart.timer`: daily at 05:00 + jitter.

---

## Code conventions

- **Overridable paths and tunables**: every script reads `GVPN_STATE_DIR`, `GVPN_NOW`, ...
  with device defaults, so bats can run it against a sandbox.
- **Sourceable scripts** guard dispatch so tests can call single functions:
  ```bash
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
  fi
  ```
- **`/usr` for image-owned config**, `/etc` only for device-specific or package-expected files.
- **Provisioning gate** on every gated unit itself; **firewall `Requires=`** on everything that listens.
- **Docs move with code**: `architecture.md` describes what is, `roadmap.md` what is not yet.
- **TDD**: write the bats test, watch it fail, then implement. `just test` output must be pristine.
- Conventional, imperative commit messages; `just test` before you push.

---

<!-- _class: small -->

## Writing a unit test

`tests/unit/helpers.bash` gives you a sandbox and recording mocks on `PATH`:

```bash
#!/usr/bin/env bats
load helpers

setup() {
  setup_sandbox                    # temp dirs; exports GVPN_STATE_DIR, GVPN_RUN_DIR, ...
  export GVPN_NOW=1790220600       # 2026-09-24T03:30:00Z
  mock_cmd timedatectl "echo yes"  # NTP synced
  mock_cmd systemctl               # records calls, exits 0
}

teardown() { teardown_sandbox; }

@test "check fails once the deadline has passed" {
  echo "2026-09-24T03:29:59Z" > "${GVPN_STATE_DIR}/support-until"
  run "${LIBEXEC}/support-window.sh" check
  [ "${status}" -eq 1 ]
}
```

- `calls` prints the recorded mock invocations; assert on outcomes first, calls where they are the contract.
- `provision_sandbox` marks the sandbox as provisioned; `seed_capacity` fakes a speed sample.

---

## Integration tests: the QEMU rehearsal

`tools/vm.sh`: q35/KVM, OVMF, **swtpm TPM2**, NVMe disk, virtio NIC → `lan0`. Real systemd, SELinux enforcing, no mocks.

```sh
export GVPN_COSIGN_PUB='/secure/path/cosign.pub'       # public half of your update key
nix develop -c tests/integration/bastion.sh start       # throwaway bastion on the host
eval "$(nix develop -c tests/integration/bastion.sh env)"
nix develop -c just iso vm-install && nix develop -c just vm-run
# second terminal
nix develop -c just test-integration unprovisioned      # then enroll, provision,
                                                        # provisioned, address
```

| Phase | Covers |
|---|---|
| `unprovisioned` / `enroll` | Gate, enrollment files, access through the bastion |
| `provision` / `provisioned` | Dummy-Safe provisioning, services, WG + shaping, capacity, tunnel |
| `address` | Operator address refresh |
| `update` | <span class="warn">Writes to the shared registry.</span> Not a local test |

Linux host only. Never flash the rehearsal ISO onto hardware.

An Incus VM also runs the same image as a production alternative to hardware
(min. 8 vCPUs, 16 GiB RAM), from the same ISO: the installer picks the only
internal disk itself. The published ISO has no SSH key, so configure access on
the console first (`just incus-console` in a VM, keyboard and monitor on
hardware) ([incus.md](../incus.md)).

---

## Shipping a change

```text
 PR ──► CI: just lint, just test, just check-pins, just build
  │
  ▼ merge to main
 CI: build + just push   (signed <repo>:<version>, no channel moves)
  │
  ▼ manual "Promote Image" workflow
 just promote <version> canary   ──► soak ──►   just promote <version> stable
```

- Versions are `git describe --tags --always --dirty` (short hashes today).
- Merge also builds the installer ISO (unmanaged, console-configured, for hardware and VMs) and publishes it signed as `iso-<version>`; its canary tag moves with `tag-iso` after image promotion. PRs build it but publish nothing.
- `promote` verifies the signature before copying the digest to a channel.
- Canary devices stage a promotion within about two hours (hourly + up to 1 h jitter)
  and apply it in their next 03:00 window.

<span class="warn">Moving a channel is a fleet change. Coordinate it; it is never a test step.</span>

---

## Sharp edges

- <span class="warn">Booting an ISO wipes its install disk (the only internal disk, or the one `GVPN_INSTALL_DISK` names) without asking.</span>
  Each managed ISO contains that device's **enrollment private key**.
- `keys/` is in the image build context: **never** put a private key there.
- The image-update pair belongs to the operator: without it the build stops.
- `/etc` changes in the image do not replace locally modified files on devices.
- A dead base-image digest fails the build with "manifest unknown" → `just update-pins`.
- Changing `GVPN_IMAGE_REPO` does not move existing devices (origin + trust migration).
- First installs from the ISO are **not** signature-verified (local transport).
- The device announces a public address its own firewall makes undialable (open decision).

---

## Known gaps worth knowing

From [`docs/roadmap.md`](../roadmap.md):

- No end-to-end proof yet of client sessions behind NAT/CGNAT, packet-level isolation,
  throughput, or DB restore after a forced rollback.
- greenboot `20-gvpn-server.sh` / `40-gvpn-shaping.sh` wait up to 60 s for the
  server and the shaping trees; real startup timings on hardware are unmeasured.
- Every red boot rejects its digest, also for an already-blessed image; no command clears rejections.
- Release gate: `-dirty` versions are refused; no tag convention yet.
- Fleet side (not implemented, part of the roadmap): heartbeat verification, alerting, SSH CA for operator rotation.
- Fedora 44 EOL mid-2027: rehearse the major rebase through canary.

Good first issues often live here. Pick one, write the failing test, open a PR.

---

## Your first week

1. Read [`AGENTS.md`](../../AGENTS.md), [`architecture.md`](../architecture.md), [`build.md`](../build.md), [`roadmap.md`](../roadmap.md).
2. `nix develop -c just test` until it is green and quiet on your machine.
3. Read one runtime script end to end with its suite, e.g. `support-window.sh` + `support-window.bats`.
4. On a Linux box: build an ISO, run the QEMU rehearsal through `provisioned`.
5. SSH into the VM and run `sudo gvpn-exit-status`; follow one unit with `systemctl cat`.
6. Walk through [`first-install.md`](../first-install.md) and [`publish-image.md`](../publish-image.md) against your own bench and registry.
7. Pick a small gap from the roadmap and ship it through the PR flow.

---

<!-- _class: lead -->
<!-- _paginate: false -->

# Questions?

`nix develop -c just test`

docs: `architecture.md` · `build.md` · `roadmap.md` · `first-install.md` · `publish-image.md` · `recovery.md` · `incus.md`
