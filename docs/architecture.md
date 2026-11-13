# Architecture

Runtime design of the exit appliance (Beelink SER8, GEEKOM A8): Fedora IoT in
bootc image mode with `hoprd`, `gnosis_vpn-server` and the device logic in
this repository. Versions are pinned in `image/versions.env`. Build and test
tooling is in [build.md](build.md), open work in [roadmap.md](roadmap.md).

## Supported environment

- Wired DHCP LAN with IPv4, outbound HTTPS (registry, Blokli, blocklist
  feed, public-IP services, Cloudflare's speed test endpoints for the
  boot-time measurement, and the optional fleet endpoint, whose backend is not
  implemented, part of the [roadmap](roadmap.md#fleet-and-onboarding)), NTS
  time sync over UDP 123 with NTS-KE over TCP 4460 to the servers in
  `/etc/chrony.conf`,
  outbound SSH to the support bastion when the device has one, and HOPR p2p
  connectivity.
- At least 30 Mbit/s in each direction. The device measures the link at boot and
  sizes the VPN capacity from it. Below that floor it still uses the measured
  share, which admits one client (see
  [Traffic shaping](#traffic-shaping-and-blocklist)).
- Not supported: Wi-Fi, static-only LANs, captive portals, IPv6-only uplinks, a
  LAN that uses `172.30.0.1` or overlaps `10.128.0.0/24` (they collide with the
  session target alias and the WireGuard pool), and more than one wired NIC.
  `10-gvpn-exit-lan0.link` renames the wired NIC to `lan0` and matches every
  wired NIC, so with two of them the name goes to one of the two and which one
  is not defined; `gvpn-exit-status` reports the candidates.
- No router port is mapped and unsolicited inbound p2p traffic is dropped.
  **Client sessions behind NAT/CGNAT are unverified**; a green boot does not
  prove that clients can use the exit.

An Incus VM is a supported alternative host for the same image, not only a
test harness; size it with at least 8 vCPUs and 16 GiB RAM. Incus supplies the
UEFI firmware, vTPM and virtio-scsi disk (`/dev/sda`). The same installer ISO
serves hardware and VMs: by default it picks the only internal disk at install
time, ignoring removable disks and its own media, and stops when there is not
exactly one ([Incus VM](incus.md)).

The firmware power mode is set to Performance when the device is prepared, and
`usr/lib/tmpfiles.d/gvpn-exit-cpu.conf` selects the performance governor on
every cpufreq policy. With amd-pstate in active mode this also pins the
energy-performance preference. `gvpn-exit-status` warns about any other
governor.

## Overview

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
Operator on the LAN (RFC1918 source) -------------------> device sshd -> devops (sudo)
```

- `172.30.0.1` is the session target address built into the GnosisVPN client.
  `gvpn-exit-loopback-alias.service` assigns it to `lo`, so session traffic
  needs no LAN route.
- `hoprd.cfg.yaml` (v5) lets sessions reach only those two targets, enables the
  PIX/Curvy payment strategy and reads its proving artifacts from
  `/usr/share/gvpn-exit/curvy-zk`. `hoprd-run.sh` renders a per-start copy into
  `/run/hoprd/` with the provisioned Blokli URL in both the top-level and
  PIX-pool fields, so a template change in an update reaches every device.
  hoprd's API listens on `127.0.0.1:3001`; p2p uses port 9091.
- gnosis_vpn-server brings `wggvpn` up through wg-quick, whose hooks
  (`wg-hooks.sh`) install forwarding, NAT and shaping. The unit's
  `ExecStopPost` runs `wg-quick down` after a crash.

Unit dependencies and sandboxing:

- Everything that listens or forwards `Requires=gvpn-exit-firewall.service`.
  hoprd also requires `gvpn-exit-data-guard.service`; address initialization and
  the uplink measurement are only `Wants=`, because both are best effort.
- `gvpn-exit-capacity.service` runs before the VPN server, measures the uplink
  and caches the sample the pool and the shaping tree are derived from.
- `gnosisvpn-server.service` (root, capabilities bounded to NET_ADMIN and
  NET_RAW) and hoprd (user `hoprd`) run with `ProtectSystem=strict`,
  `ProtectHome=yes`, `PrivateTmp=yes`, `NoNewPrivileges=yes` and
  `SystemCallFilter=@system-service`. The server keeps `/run` writable for the
  iptables lock its hooks take.
- The enrollment and support tunnels run as `DynamicUser=yes` without
  capabilities; their SSH key arrives as a systemd credential.

## Configuration

Image-owned configuration lives under `/usr`. `/etc` holds device-specific
files and files that packages expect there. bootc three-way merges `/etc`: a
locally modified file keeps its content across updates. Scripts live in
`/usr/libexec/gvpn-exit/`; their paths and tunables are overridable through the
environment for tests.

| Path | Content |
|---|---|
| `/usr/share/gvpn-exit/exit.env` | Network, peer pool, shaping, capacity policy and blocklist defaults |
| `/etc/gvpn-exit/exit.env` | Device overrides. `load_exit_env` evaluates it once in a subshell that holds the defaults and takes over what it sets, so it can build on a default and a file that fails costs only the overrides |
| `/usr/share/gvpn-exit/{iptables,ip6tables}.rules` | Static firewall |
| `/usr/share/gvpn-exit/hoprd.cfg.yaml`, `hoprd.env` | hoprd v5 defaults (PIX, Curvy artifacts, v5 data path); the Blokli URL in the file is a placeholder for schema validation; hoprd-run.sh refuses to start without a provisioned URL |
| `/run/hoprd/hoprd.cfg.yaml` (0644) | Per-start copy of the template with every `blokli_url` (top level and the PIX pool's own) set to the provisioned endpoint |
| `/etc/hoprd-v5/hoprd.env.d/10-provisioned.env` | Safe, module and Blokli URL for hoprd v5 |
| `/etc/hoprd/hoprd.env.d/10-provisioned.env` | v4 provisioning file, read by the v4 cleanup helper; not loaded by hoprd.service |
| `/usr/share/gvpn-exit/wggvpn.conf.in` | WireGuard template, rendered to `/run/gnosisvpn-server/` |
| `/etc/gvpn-exit/support.env`, `bastion_known_hosts` | Bastion, reverse port and pinned bastion host key; absent on an unmanaged device |
| `/etc/gvpn-exit/enroll.key` | Installer enrollment key (root 0600), bastion devices only; `finalize` removes it |
| `/var/home/devops/.ssh/authorized_keys` | Keys that log in as `devops`: the installer's, and what the operator adds ([local access](local-access.md)) |
| `/etc/gvpn-exit/fleet.env` | Optional `GVPN_FLEET_URL`, the heartbeat target (fleet backend: not implemented, part of the [roadmap](roadmap.md#fleet-and-onboarding)) |
| `/etc/chrony.conf` | NTS sources (Cloudflare, Netnod, PTB) instead of the Fedora pool; DHCP-supplied servers are used through `sourcedir` |
| `/etc/greenboot/greenboot.conf` | Boot attempts, watchdog grace, disabled stock checks |
| `/etc/containers/policy.json`, `registries.d/` | Signature policy for the repository rendered at build time; sigstore attachments |

## Persistent state

The ISO kickstart pins the NVMe layout: `/boot/efi` 600 MiB vfat, `/boot`
2 GiB XFS and `/` XFS over the rest of the disk; swap is Fedora's zram. DB
snapshots use `cp --reflink=always`, so `/` must support reflinks (the XFS
default); without them a snapshot, and therefore the update, fails. All
bootc deployments share `/var`, so booting another image does not roll
application data back (see [rollback of application data](#rollback-of-application-data)).

| Path | Content |
|---|---|
| `/var/lib/gvpn-exit/identity/` (root 0700) | `provisioned` marker, `serial`, `node.json`, `provisioning.json` |
| `/var/lib/gvpn-exit/creds/` (root 0700) | TPM2-sealed credentials |
| `/var/lib/gvpn-exit/state/` | `data-owner`, `data-owner-previous`, `rejected-digests` (last 10), `support-until`, `reachability.json`, `hoprd-host.env`, `capacity.env` (last uplink sample), `hoprd-v5-migrated` (v4-to-v5 cleanup timestamp), watchdog restart counter |
| `/var/lib/hoprd-v5/` (hoprd 0700) | Live hoprd v5 DB |
| `/run/hoprd/hopr-v5.id` (hoprd 0600) | Per-start copy of the sealed identity; the v4 source is untouched, and hoprd may migrate the copy in place |
| `/var/lib/hoprd-v5.snapshots/<digest>/` | Pre-update snapshot of the v5 DB (reflink copy); parent root 0700 |
| `/var/lib/hoprd-v5.rejected-<epoch>/` | v5 DB set aside on rollback; data-guard prunes it at the first boot after 7 days |
| `/var/lib/hoprd/` (hoprd 0700) | v4 DB, kept for the migration helper and a rollback to the previous deployment |
| `/var/lib/hoprd.snapshots/<digest>/` | v4 pre-update snapshot, restored by a v4 rollback |
| `/var/lib/gnosisvpn-server/` | Server state; peers are ephemeral |
| `/var/lib/gvpn-blocklist/blocklist.cidr` | Feed cache, seeded from the snapshot taken at image build |
| `/var/lib/node_exporter/textfile/` | Blocklist and hoprd restart metrics |
| `/var/lib/netdata`, `/var/cache/netdata` | Monitoring data |

Data ownership and rejections identify deployments by image digest
(`sha256:...` from `bootc status --format=json`).

## Provisioning

`sudo gvpn-exit-provision` runs as `devops` over LAN SSH or the enrollment
tunnel ([runbook](first-install.md#5-provision)).

1. `identity` requires a TPM2 and refuses to replace an existing identity. It
   creates the hoprd identity, password, API token, WireGuard key and support
   SSH key in a private `/run` directory, seals them and prints the node
   address, peer id and support public key.
2. The operator creates and funds the Safe and module elsewhere and, on a
   device with a bastion, admits the support key there.
3. `finalize --safe-address --module-address --blokli-url --location [...]`
   writes the v5 device configuration (`/etc/hoprd-v5/hoprd.env.d`), opens a support window when a bastion is
   configured (default 90 days) or `--support-days` is given (requires NTP
   sync), records the data owner and
   the provisioning record, writes the `provisioned` marker and removes
   `enroll.key`.
4. The reboot starts the exit services, and on a device with a bastion the
   support tunnel with the sealed key replaces the enrollment tunnel. `finalize` runs once per device: a
   second run is refused, so a re-run cannot rewrite the ownership record or
   extend the support window.

### Updating a v4 device to hoprd v5

The v5 service keeps `/var/lib/hoprd` and `creds/hopr.id.cred` untouched (only
the migration helper runs the v4 binary on that database) and starts from
`/var/lib/hoprd-v5` and a per-run identity copy. Until the operator
runs [`gvpn-exit-hoprd-migrate`](hoprd-v5-migration.md), hoprd.service is held
stopped by a condition on `/etc/hoprd-v5/hoprd.env.d/10-provisioned.env`; the
required boot check reports the pending migration instead of a red boot, so the
update still boots green but the exit serves nothing until the migration. That
keeps the v5 strategies from opening channels or depositing PIX from the old
Safe before its funds move. The helper runs the bundled v4 binary on the old
database and identity, which updates that v4 database as it redeems tickets and
closes channels, withdraws the old Safe's balance to the new Safe, writes the v5
provisioning file and starts hoprd. The old provisioning file, database and
sealed credentials stay readable afterwards; the v4 binary can be removed once
the fleet is migrated.

### Provisioning gate

Every unit and timer that must not run unprovisioned carries
`ConditionPathExists=/var/lib/gvpn-exit/identity/provisioned` itself, because
conditions do not propagate through `Requires=` (`tests/unit/units.bats`
enforces this). The gate covers hoprd, data-guard, address initialization, the
capacity measurement, the VPN server, feed refresh, netprobe, health restarts,
updates, the support tunnel and the heartbeat, which also needs `fleet.env`.

Of the appliance services, only the firewall, the loopback alias, the cached
blocklist load, sshd, chronyd, node_exporter and netdata run unprovisioned,
plus `enroll-tunnel.service` while `support.env` and `enroll.key` exist.

## Credentials

Credentials are sealed with `systemd-creds encrypt --with-key=tpm2
--tpm2-pcrs=`: only this TPM can decrypt them, and without a PCR policy
firmware and OS changes do not lock them out. Root on the device can read
them; sealing is neither disk encryption nor an access boundary for operators.
Secure Boot and LUKS are [phase 2](roadmap.md#phase-2).

| Credential | Delivered with `LoadCredentialEncrypted=` to |
|---|---|
| `hopr.id` | `hoprd-run.sh`, which copies it to `/run/hoprd/hopr-v5.id` and points hoprd there |
| `hoprd.password`, `hoprd.api-token` | `hoprd-run.sh`, which exports them into hoprd's environment |
| `wg.key` | `render-wg-conf.sh`, which writes `/run/gnosisvpn-server/wggvpn.conf` (0600) |
| `support.key` | The support tunnel (autossh identity) and heartbeat signing; the greenboot hooks decrypt it themselves |

The enrollment key is a plaintext installer file and is also on the
per-device ISO.

## Network and firewall

- `10-gvpn-exit-lan0.link` renames the wired Ethernet NIC to `lan0` (any
  `Type=ether` device: the SER8's and A8's r8169 for the RTL8125, the QEMU
  test's virtio_net, or another PHY on a board revision) and enables receive
  packet steering on all CPUs, because r8169 gives the RTL8125 a single receive
  queue.
- NetworkManager runs DHCP on `lan0` and leaves `wggvpn`, `ifb-gvpn` and
  Wi-Fi devices unmanaged. Intel Wi-Fi and USB Bluetooth drivers are
  blacklisted.
- IPv4 forwarding is on. Host IPv6 is disabled, and ip6tables drops all IPv6
  except loopback.
- `net.core.{r,w}mem_{default,max}` are 4 MiB. hoprd's QUIC sockets inherit
  the defaults, so raising only the maxima would not enlarge them. Defaults
  apply to new sockets only, so restart hoprd after a change and check for
  `rb4194304`/`tb4194304` in `sudo ss -u -a -n -m -p`.

`gvpn-exit-firewall.service` loads the static IPv4 rules before the network
comes up:

- INPUT and FORWARD default to DROP, OUTPUT to ACCEPT.
- INPUT accepts loopback, established/related traffic, SSH on `lan0` from
  RFC1918 sources, DHCP and ICMP echo on `lan0`. The router's answer to
  `netprobe.sh`'s SSDP discovery is not tracked by conntrack, because the query
  goes to a multicast group and the answer comes from the router's own address
  to an ephemeral port. That script therefore accepts UDP from the default
  gateway with source port 1900 for the duration of a probe, rather than
  opening the router's source ports to the whole LAN; its NAT-PMP query is a
  unicast exchange with the gateway, so the conntrack rule covers that answer.
  From `wggvpn` it accepts only the echo request the client sends to the
  WireGuard server address before it reports the tunnel up (`connection.ping`,
  default `10.128.0.1`), and drops everything else. No inbound p2p port is
  open.
- FORWARD from `wggvpn` jumps to `GVPN_PRIVATE` first. That chain drops
  10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16, 127/8, 0/8, 224/3 and the
  `gvpn-self` set: this device's own public IPv4 addresses (announced,
  HTTPS-observed, router-reported), which would otherwise be masqueraded to the
  router or hairpinned to a LAN host. Other publicly addressed LAN
  destinations are not covered.
- `self-ipset.sh` fills `gvpn-self` before `iptables-restore`, which resolves
  set names while loading, and refreshes it after every netprobe run and
  address change.

The required boot check reads the live chains rather than the files, and judges
a rule ahead of the isolation point by what it can do, not by its text. What may
stand there: a DROP, a REJECT, a RETURN into the DROP policy, a target that only
logs or marks the packet, and an ACCEPT that cannot match traffic arriving on
`wggvpn` — the loopback rule, the verification ping, a rule for another
interface, and, in INPUT only, the established-connection rule (the host opens
no connection to a client, so nothing on the tunnel is established with it). What
fails the boot: an ACCEPT without `-i`, which matches the tunnel too, an
interface wildcard that covers it (`-i wg+`), a state list that also names NEW, a
jump to a chain whose verdict the check cannot see, and a queue that hands the
packet to a program outside the ruleset.
One case the printed text cannot settle: `iptables` installs an interface name
with spaces in it with nothing but a warning and prints it back unquoted, so a
rule with no target whose interface is named `wggvpn -j DROP` prints exactly like
the drop. Installing one takes root on the device, which can remove the ruleset
outright; the check is a guard against a ruleset that drifted, not against its
owner.

`wg-hooks.sh up` installs the dynamic rules guards-first: the tunnel-ping
allowance the client needs on INPUT (from `WIREGUARD_CIDR` to
`WIREGUARD_ADDRESS`, ahead of the `wggvpn` drop, so a changed pool cannot leave
it behind), blocklist drops in
both directions and a second, comment-tagged `GVPN_PRIVATE` jump at the head of
FORWARD, then the TCP MSS clamp on both sides of the tunnel, shaping,
MASQUERADE and the uplink ACCEPT at the tail. `down` removes them in reverse
order and never touches the static jump.

The clamp sets the MSS to `WIREGUARD_MTU - 40` (IPv4 and TCP headers) in the
mangle FORWARD chain, matching `SYN,RST SYN` so it also rewrites the MSS a
server announces in its SYN-ACK. A TCP origin that sizes its segments from a
larger interface than the tunnel — a host or container behind the client, or a
client whose stack does not follow its TUN MTU — would otherwise pull segments
out of the internet that do not fit into `wggvpn`. The exit drops those with DF
set, and a server that ignores the resulting ICMP frag-needed stalls the
connection after the handshake opens. TCPMSS never raises an announced value,
so clients that already announce the tunnel MSS are unaffected.

sshd accepts only `devops` and only with a key. A NetworkManager dispatcher
script binds it to the current `lan0` address and loopback when `lan0` comes up
and on every DHCP lease change; it labels that runtime drop-in like sshd's own
configuration, because SELinux otherwise keeps sshd from reading it. Until
then sshd listens on all addresses, still restricted by the firewall. The installer
locks root's password and, for a key-configured ISO, devops' password too. A
console-configured ISO gives devops a temporary password and expires it, and
enables `serial-getty@ttyS0` only when the installed system runs in a VM; on
hardware the console is tty1. sshd still refuses passwords, but the console
accepts the devops password until the operator locks it
(`sudo passwd -l devops`). devops has passwordless sudo.

## Traffic shaping and blocklist

Capacity is measured, not assumed. On every provisioned boot
`gvpn-exit-capacity.service` runs before the VPN server and probes the uplink
against Cloudflare's speed test endpoints (`GVPN_CAPACITY_URL`), unless the
aggregate is pinned in `/etc/gvpn-exit/exit.env`: then the sample would not be
what the device shapes to, so the run is recorded as skipped. The probe is
curl only, with no client software of its own. An empty request first proves
the endpoint is reachable, names the Cloudflare data centre (`CF-RAY`) and
reads the edge's minimum RTT from `Server-Timing`. Then each direction runs
four streams of back-to-back 50 MB requests on reused connections (`__down`,
`__up`), discards the first 3 s and counts the bytes `lan0` moves in the next
8 s. Cloudflare's anycast network answers from its nearest data centre, so
there is no server list to get wrong, and the long-lived streams leave TCP slow
start before the window opens: a probe with a few short requests on a high-RTT
path under-reports a healthy link by more than half, because the transfer ends
while the congestion window is still growing. A stream that ends inside the window, through
a rejected request or a stall, fails the probe instead of under-reporting.
Cloudflare sees the device's public address, as the public-IP lookup already
does. A measured sample is cached in
`state/capacity.env`. `lib.sh` turns it into the shaping knobs after the device
overrides, so a pin in `/etc/gvpn-exit/exit.env` always wins:

- **aggregate** = floor(min(measured download, measured upload) / 4). The exit's
  VPN traffic gets a quarter of the public link; hoprd, netdata, image updates
  and the operator keep the rest. 200 Mbit/s → 50 Mbit/s.
- **peer slots** = floor(aggregate / 5 Mbit/s), at least one and at most the last
  usable address of the `/24`. One WireGuard pool address and one shaping class
  per slot. 50 Mbit/s → ten clients.
- **per-peer ceiling** = min(10 Mbit/s, aggregate): what one client may use.
- **per-peer guarantee** = min(ceiling, aggregate / slots): that client's HTB
  share, so the guarantees never over-subscribe the aggregate.

The pool is a limit on registered clients, not on people: a client keeps its slot
until `gnosisvpn-server` cleans the registration up, and a peer that never sends
traffic still occupies one. Changing the pool or the rates requires a server
restart, which is why the measurement runs before the server starts. An operator
re-measurement is disruptive: `systemctl restart gvpn-exit-capacity.service` and
then `systemctl restart gnosisvpn-server.service` drops every client.

The probe is best effort and never gates the VPN (the server only `Wants=` it).
Without an IPv4 address or default route on `lan0` it is skipped; an
unreachable endpoint, a stream that ends early or an implausible rate keeps
the last good sample. A rate below `GVPN_CAPACITY_MIN_KBIT` (1 Mbit/s) in
either direction is implausible too: the probe completed on a link throttled
to a trickle. With no sample at all the device assumes the
supported-environment floor: 30 Mbit/s → 7.5 Mbit/s aggregate and one slot.
`GVPN_CAPACITY_STREAMS`, `GVPN_CAPACITY_WARMUP_S` and `GVPN_CAPACITY_WINDOW_S`
tune the probe. `gvpn-exit-status` warns about a fallback or a failed
probe, the heartbeat carries the sample and the derived values, and no outcome
can fail a required greenboot check: a measured aggregate that cannot give
every slot of a pinned pool 1 kbit/s falls back to the floor as well, so a
sample never leaves shaping without its values. One probe per boot costs 11 s of line
rate in each direction (about 140 MB each way at 100 Mbit/s); a pinned
aggregate costs none, and a server restart reuses the cached sample instead of
measuring again.

Defaults in `exit.env`:

- WireGuard pool `10.128.0.0/24`, server `.1`, peers `.2` upward (the end is
  derived from the measurement), UDP 51820, MTU 1420.
- HTB with fq_codel leaves per direction. Download is shaped on `wggvpn` egress;
  upload is redirected from `wggvpn` ingress to `ifb-gvpn`. The aggregate class
  holds one class per peer slot; non-peer traffic (the server address,
  broadcasts) has its own capped sibling class, so it cannot eat into the
  guarantees. `lan0` itself is not shaped.
- FireHOL level1 in ipset `gvpn-blocklist` (`hash:net`, at most 131072
  entries). `wg-hooks.sh` drops forwarded traffic to and from it.

The blocklist fails open. A refresh replaces the set (atomic `ipset swap`) only
if every feed downloaded and the parsed list holds 1000 to 131072 entries;
otherwise the last good list stays and the metrics report the failure. The
parser drops prefixes shorter than /8 outside 224/3, so a poisoned
`0.0.0.0/1` cannot blackhole every session. Boot loads the cache before the VPN
server starts; refresh runs at 03:00 and 15:00 plus up to 1 h. Private-range
isolation does not depend on the feed.

The feed is trusted by URL, not by content: the default is FireHOL's level1
aggregate on its upstream branch, which moves and is not authenticated. The
parser, the entry-count band and the coverage ceiling bound what a poisoned
feed can do; a deployment that needs fixed content mirrors the feed and points
`GVPN_BLOCKLIST_FEEDS` at the mirror ([roadmap](roadmap.md#pending-decisions-in-the-code)).

## Reachability

On every provisioned boot until `state/hoprd-host.env` exists,
`gvpn-exit-hoprd-address.service` runs before hoprd. It asks
checkip.amazonaws.com, api.ipify.org and Cloudflare's trace endpoint (10 s
each), takes the first valid public IPv4, logs any disagreement and saves
`HOPRD_HOST=<ip>:9091` with `HOPRD_ANNOUNCE=1`. On failure hoprd starts
unannounced and the next boot tries again. The saved address never changes on
its own; after an uplink change or a move to the site run:

```sh
sudo gvpn-exit-hoprd-address refresh   # discover, save, restart hoprd
```

A failed discovery or write keeps the previous file and does not restart
hoprd. A failed restart reports that the new address is saved but inactive.

Announcing is not reachability: the firewall still drops unsolicited 9091 and
no router port is mapped, so the node announces an address that does not
accept connections. Whether to announce at all is an
[open decision](roadmap.md#pending-decisions-in-the-code).

`netprobe.sh` runs every 15 minutes and writes `state/reachability.json`: the
HTTPS-observed IPv4, the router's external address from UPnP-IGD or NAT-PMP
(read-only, 10 s per call) and a heuristic NAT label. `cgnat` means a
100.64/10 address was seen, `ok` that both observations match, `double_nat`
that the router reports an RFC1918 address (which can still be carrier NAT),
and `unknown` everything else, including offline runs. It maps no port and does not touch hoprd's address.
`gvpn-exit-status` and the heartbeat compare the announced with the observed
address and flag drift.

## Boot health

greenboot allows 3 boot attempts with a 24-hour watchdog grace. The stock
repository-DNS and update-platforms checks are disabled: an offline boot must
not count as broken, and the appliance manages its own updates. Appliance
checks skip on unprovisioned devices.

| Class | Checks | On failure |
|---|---|---|
| Required | Firewall, data-guard (succeeded), blocklist load, VPN server, node_exporter, netdata and sshd active within 180 s; no VPN-server restart; server API ping; `wggvpn` port and 0600 config; isolation rules, tunnel-ping rule, `gvpn-self` rule and set, IPv6 policies; HTB roots on `wggvpn` and `ifb-gvpn` | Red boot; can roll back |
| Required while Blokli answers | hoprd active within 180 s, then stable for another 60 s (chain sync is not required) | Red boot; can roll back |
| Wanted | Default route and DNS, Blokli, hoprd `/healthyz`, blocklist size, netdata and node_exporter | Logged only |

The wanted DNS check resolves `hub.hoprnet.org` unless `GVPN_DNS_PROBE_HOST`
names another host.

An offline device therefore boots green when its local software is healthy,
which says nothing about client sessions. The green hooks send a green
heartbeat and prune snapshots of digests that are neither booted, rollback nor
staged. The red hook records the booted digest as rejected (last 10 kept) and
sends a red heartbeat. greenboot-rs reboots after a red boot even when no
update was applied; whether GRUB's boot counter ends that loop on an Anaconda
install is [unverified](roadmap.md#tests-not-yet-built).

greenboot-rs arms its rollback trigger from the staged deployment on every
orderly shutdown, including a download-only deployment that is waiting for the
maintenance window. A drop-in replaces that `ExecStop` with
`rollback-trigger.sh`, which skips arming while
`.status.staged.downloadOnly` is true and otherwise runs greenboot's own
command, also when bootc status cannot be read. Without it, any reboot while
an update waits would roll back to the previous image and restore its stale DB
snapshot.

## Updates

- The device tracks a channel tag (`canary` or `stable`) of `GVPN_IMAGE_REPO`.
  `policy.json` rejects by default and requires a sigstore signature by
  `/etc/pki/containers/gvpn-exit-os.pub` for that repository; without the key
  every update fails. That key is the build input `GVPN_COSIGN_PUB`: each
  operator ships devices that trust the key that operator can sign with. Local
  transports are accepted unsigned, so the first install from the ISO is not
  signature-verified.
- Any image signed by that key for that repository is accepted, including an
  older one: there is no minimum-version floor yet
  ([phase 2](roadmap.md#phase-2)). The channel tag, not the device, decides
  what a device sees.
- The stock `bootc-fetch-apply-updates`, `rpm-ostree-countme` and
  `fwupd-refresh` timers are masked.
- Stage, hourly plus up to 1 h: skip the channel digest if this device rejected
  it, otherwise `bootc upgrade --download-only`. An ordinary reboot never
  finalizes a download-only deployment.
- Apply, at 03:00 plus up to 2 h: proceeds only if an update is staged, its
  digest is not rejected (checked again, because the tag can move between
  lookup and pull), local time is 03:00-05:59 and hoprd is not starting or
  stopping. The installer sets UTC; timers use device local time.
- `sudo systemctl start gvpn-exit-update-apply-now.service` applies a staged
  update immediately; it skips only the time window.
- Staging and both apply services serialize on `/run/gvpn-exit/update.lock`.

Do not run a plain `bootc upgrade` and reboot: without the snapshot and
ownership record, data-guard keeps hoprd down.

## Rollback of application data

Image rollback does not restore `/var`, and a DB migration can leave the
previous hoprd unable to read the live DB. `update-apply.sh` therefore:

1. stops hoprd and reflink-copies its v5 DB to
   `hoprd-v5.snapshots/<current digest>`;
2. releases the staged deployment (`bootc upgrade --from-downloaded`);
3. writes `data-owner-previous=<current>`, then `data-owner=<staged>`, syncs
   and reboots.

A failed snapshot or release restarts hoprd and does not reboot.

On every boot `data-guard.sh` compares the booted digest with these records.
A match with `data-owner` passes. A match with `data-owner-previous` is a
rollback: the live v5 DB moves to `hoprd-v5.rejected-<epoch>`, the v5 snapshot
is restored and the booted digest becomes the owner. Anything else, or a
missing snapshot, fails the unit and keeps hoprd down.

**Accepted loss:** tickets and channel state written after the snapshot are
missing from the restored DB, and the Curvy pool's `curvy-pix.redb` state rolls
back with it. Channel state re-syncs from Blokli; unredeemed tickets from that
window are lost. The rejected DB is kept for 7 days but not
replayed. Identity and credentials are not part of the snapshot.

The steps are not one crash-safe transaction. Power loss between them can
require operator recovery; only mocked unit tests cover interruptions.

## Support tunnel

The tunnel exists only on a device whose installer was built with the bastion
inputs, a managed device ([the setups](first-install.md#choose-your-setup)).
Both tunnel units require `/etc/gvpn-exit/support.env`, so an unmanaged device
starts neither, dials nowhere for support and is administered over
[LAN SSH](local-access.md) alone; the support window then gates nothing.

`support-tunnel.sh KEY` runs autossh with a reverse forward from
`SUPPORT_PORT` on the bastion's loopback to the device's `127.0.0.1:22`. It
pins the bastion host key (`StrictHostKeyChecking=yes`) and fails on
forwarding errors. autossh reconnects on its own; systemd restarts it 60 s
after it exits. The bastion, operated outside this
repository, must restrict each key to its own reverse port (`permitlisten`);
`tests/integration/bastion.sh` shows the restriction.

- `enroll-tunnel.service`: installer key, unprovisioned devices only, no time
  limit.
- `support-tunnel.service`: sealed support key, only while
  `state/support-until` parses, the clock is NTP-synchronized and the deadline
  lies ahead. A timer reconciles 2 minutes after boot and then every 5
  minutes, so expiry takes effect within 5 minutes. An unsynchronized clock
  stops the tunnel but keeps a valid deadline.

`sudo gvpn-exit-support extend <1-90 days> | close | status` manages the
window; `extend` requires NTP sync. `extend`, `close` and the timer's reconcile
run take the same lock, so a recovery request the timer has already read cannot
reopen a window that `close` removed. The window is a root-written timestamp,
not a signed authorization, and gates only the tunnel, not LAN SSH or sudo.

### What the support window trusts

The window exists so an operator can reach an appliance whose owner is not on
site, without leaving a permanent inbound path. It is worth being explicit
about what it does and does not buy, because it is the largest standing
privilege on the device:

- **What it grants.** While the window is open, whoever holds the bastion and a
  key admitted there reaches the device's `sshd` as `devops`, which has
  passwordless sudo. In effect the bastion's operator set has root on every
  device with an open window. That is the design: the alternative is a device
  nobody can repair without sending someone to it.
- **Who can open it.** Root on the device (`gvpn-exit-support extend`, and
  `finalize`, which opens 90 days by default when a bastion is configured), or
  someone with physical access and the recovery stick, which leaves a
  `state/recovery-request` the timer turns into a window once the clock is
  trusted ([recovery](recovery.md)). Nothing else can: the request is a file
  root writes, and the timer only reads it.
- **What it does not do.** It is not an authorization the device can verify.
  The device cannot tell an operator session from an intruder who has the
  bastion, and it does not try: `sshd` and sudo are unchanged by the window.
  Compromise of the bastion, of an operator key or of the device's own root is
  outside what a timestamp can bound, and a signed grant would not change that
  either, because the verifier would live on the same device.
- **Why a timestamp and not a signed authorization.** A signed grant needs a
  trust root, a revocation story and a party that can issue it; the fleet
  backend that would be that party is not implemented
  ([roadmap](roadmap.md#fleet-and-onboarding)). Until it exists, a signature
  would add a second key to protect without removing the bastion from the
  trusted set, since the bastion still carries every session.
- **What bounds it.** The window is at most 90 days, `close` ends it, the timer
  reconciles every 5 minutes so an expired window stops the tunnel within that
  period, an unsynchronized clock stops the tunnel, the bastion restricts each
  key to its own reverse port ([bastion](bastion.md)), and the heartbeat
  reports the deadline so a window nobody needs shows up in the fleet's
  telemetry. LAN SSH and the `devops` sudo rule are separate from all of this
  and remain the device owner's.

[recovery.md](recovery.md) covers the device that has neither: `finalize`
deletes the enrollment key, so a provisioned appliance with no working operator
key has no remote path back. The recovery stick adds the operator keys and
leaves `state/recovery-request`, which the timer above turns into a support
window once the clock is trusted; it also moves the expiry of the stick's keys
to that window's deadline.

## Observability and operator access

- node_exporter on `127.0.0.1:9100` with the systemd and textfile collectors:
  `gvpn_blocklist_*`, `hoprd_service_restarts_systemd` (gauge; systemd counts
  only `Restart=` restarts and zeroes it on any other start) and
  `hoprd_watchdog_restarts_total` (counter).
- netdata on `127.0.0.1:19999`, registry and cloud disabled, anonymous
  statistics opted out. Reach it with SSH local forwarding.
- `hoprd-health.sh`, every minute: after a 15-minute startup grace, 3
  consecutive failed `/healthyz` probes trigger `systemctl try-restart hoprd`,
  but only once a probe has succeeded since the current start, because an
  unfunded node keeps its API closed. `try-restart` leaves a stopped hoprd
  stopped. `hoprd-preventive-restart.timer` restarts hoprd daily at 05:00 plus
  up to 1 h, without catch-up, so the fleet does not restart in lockstep.
- Heartbeat, only with `fleet.env`: 5 minutes after boot, then every 15
  minutes plus up to 60 s, and from the green and red hooks. It POSTs the device
  id, image, boot verdict, service states, blocklist age, staged digest,
  support deadline, announced address and drift, `reachability.json` and the
  rejected digests, and fails its unit when the endpoint answers with an HTTP
  error. The body carries an SSH
  signature by the support key over `jq -cS 'del(.signature)'` of the payload,
  verifiable with `ssh-keygen -Y verify -n gvpn-exit-heartbeat` against
  `support_public_key` in the provisioning record. Without a usable key it
  sends `signature: null`. Verification and alerting belong to the fleet
  backend (not implemented, part of the
  [roadmap](roadmap.md#fleet-and-onboarding)).
- `sudo gvpn-exit-status` reports provisioning, Blokli, firewall, hoprd,
  WireGuard, reachability, CPU and netdata, and exits 1 on any FAIL. Without
  root the provisioning state shows as unknown (WARN), gated sections are
  skipped and root-only checks show n/a. The SSH MOTD points to it.
- `top`, `htop`, `atop` and `ethtool` are installed for diagnostics.

Operators log in as `devops` over LAN SSH or the support tunnel, with the
installer-provided key or, on a device installed from a console-configured
ISO, the key they added on the console. The operator commands are
`gvpn-exit-provision`, `gvpn-exit-support`, `gvpn-exit-status`,
`gvpn-exit-hoprd-address refresh` and, on a device updated from hoprd v4,
`gvpn-exit-hoprd-migrate`.
