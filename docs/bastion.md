# Support bastion

A bastion is for devices that are administered remotely
([managed setup](first-install.md#choose-your-setup)). A device whose operator
only works on it from its LAN needs none: build its installer without the
bastion inputs and read [local access](local-access.md) instead.

The device dials out; nothing on the appliance network has to accept an
inbound connection. Each appliance keeps a reverse SSH tunnel to a bastion you
operate, and the bastion's loopback then has one port per device that forwards
to that device's sshd ([why it looks like
this](architecture.md#support-tunnel)).

This page is the minimum a bastion has to be. It is infrastructure of your own:
any host with `sshd` that you can reach from the device and from your
operators will do. The repository contains no bastion code; the throwaway one
the integration tests use (`tests/integration/bastion.sh`) is a rehearsal of
what follows.

## What the device needs from you

For every appliance, before you build its installer ([first
install](first-install.md#1-prepare-the-bastion)):

| Input | What it is |
|---|---|
| `GVPN_BASTION` | `user@host`, or `ssh://user@host:port` for a non-default SSH port. The account is the one the device's key logs in as. |
| `GVPN_SUPPORT_PORT` | A port on the bastion's loopback that belongs to this device only, 1024-65535. |
| `GVPN_ENROLL_KEY` | The private half of a key pair you generate for this device's first access. The ISO carries it. |
| `GVPN_BASTION_KNOWN_HOSTS` | The bastion's host key in `known_hosts` form, so the device pins it. |

The device authenticates with a key and asks for one reverse forward:
`-R <port>:127.0.0.1:22`, which `sshd` resolves to `localhost:<port>`. It never
executes a command on the bastion.

## A minimal bastion

One unprivileged account, a dedicated `sshd`, and one `authorized_keys` line
per device. Run it as a second `sshd` instance so it cannot change the host's
own SSH policy:

```sh
# /etc/ssh/sshd_gvpn_bastion_config
Port 2222
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/sshd-gvpn-bastion.pid
AuthorizedKeysFile /etc/ssh/gvpn-bastion/%u/authorized_keys
AllowUsers gvpn-bastion
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
PermitTTY no
ClientAliveInterval 30
ClientAliveCountMax 3
```

- `ClientAliveInterval` and `ClientAliveCountMax` drop a session within about
  90 seconds once its device stops answering. Without them, a device that loses
  power or its uplink leaves a session that holds its reverse port for hours
  (until TCP keepalive gives up), and the device cannot bind that port again
  when it comes back. sshd checks only a session that has been idle for the
  interval, so connecting to a dead device's port again and again keeps that
  session; leave more than the interval between attempts.
- `GatewayPorts no` keeps every reverse forward on `127.0.0.1`: a device can
  never expose its sshd to the internet through the bastion.
- `AllowTcpForwarding yes` has to be the server-level setting, because an
  operator reaches a device through this sshd (`ssh -J`, or `-L` when the jump
  host cannot resolve `127.0.0.1` where you expect). What a key may forward is
  then narrowed per key, below.
- The account needs no shell, no home directory beyond its key file and no
  sudo.

Each device key carries its own restriction, so a compromised device cannot
open another device's port, run a command in the account or reach the
bastion's own network:

```text
restrict,port-forwarding,permitopen="localhost:1",permitlisten="localhost:22001",command="false" ssh-ed25519 AAAA... gvpn-exit-enroll-SERIAL
```

- `restrict` switches every permission off: shell, pty, agent, X11 and all
  forwarding. `port-forwarding` switches forwarding back on, because the
  device needs the reverse direction.
- `permitlisten` names the one port the key may bind, and it must say
  `localhost`, not `127.0.0.1`, because that is what `ssh -R` without a bind
  address asks for.
- `permitopen` confines local (`-L`) forwarding, which the same key would
  otherwise allow anywhere the bastion can reach. It takes host:port pairs and
  no "none", so name a port nothing listens on. OpenSSH has no keyword that
  allows remote forwarding alone; leaving `permitopen` out grants the local
  direction as well.

A typo in any of these makes `sshd` ignore the whole key ("bad key options" in
its log), and the device then has no remote path at all. Check the file with
`sshd -t -f <config>` and watch the log the first time a device connects.

Start it with `sshd -f /etc/ssh/sshd_gvpn_bastion_config` (systemd unit, or
`-D` under your supervisor), and give its host key to the ISO as
`GVPN_BASTION_KNOWN_HOSTS`:

```sh
printf '[bastion.example.org]:2222 %s\n' \
  "$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" > bastion_known_hosts
```

## Onboarding one device

1. Pick the next free port and write it in your device register.
2. Generate the enrollment pair: `ssh-keygen -q -t ed25519 -N '' -C
   gvpn-exit-enroll-<serial> -f <serial>.enroll`. Keep the private key in a
   safe place only long enough to build the ISO; the ISO itself carries it.
3. Add the line above with the public key and the device's port to the
   account's `authorized_keys`.
4. Add the operator keys that will reach this device ([operators'
   keys](#operators-keys)). Without them the device is reachable only through
   the enrollment key that `finalize` deletes.
5. Build the ISO with that private key, the port, the bastion address and the
   known_hosts file ([first install](first-install.md#build-it-locally)).

Provisioning creates a second, TPM-sealed support key and prints its public
half. Admit it with the same restriction and the same port, then follow the
install runbook: the reboot replaces the enrollment tunnel with the support
tunnel, and you revoke the enrollment key.

## Reaching a device

```sh
ssh -J gvpn-bastion@bastion.example.org:2222 -p 22001 devops@127.0.0.1
```

Without `-J` (a jump host that may not resolve `127.0.0.1` where you expect),
two steps work as well:

```sh
ssh -N -L 22001:127.0.0.1:22001 gvpn-bastion@bastion.example.org -p 2222 &
ssh -p 22001 devops@127.0.0.1
```

A device is reachable this way only while its support window is open
(`sudo gvpn-exit-support status` on the device); the enrollment tunnel has no
time limit, the provisioned one does.

## When a device loses its keys

The recovery stick rewrites access on the appliance itself
([recovery](recovery.md)): it prints and reports the serial, the bastion and
port from `support.env`, the device's support public key and its host key. With
that report you can restore the device's `authorized_keys` line on the bastion:

```text
restrict,port-forwarding,permitopen="localhost:1",permitlisten="localhost:<port>",command="false" <support public key>
```

Then connect as above, install the permanent operator keys, and close the
window when the work is done. Keep the device register in version control: it
is your record of which key may bind which port.

## Operators' keys

Operators log in with their own keys, one line per person and device port.
Like a device key, an operator key gets no shell and no PTY; unlike a device
key, it may forward to the one port it is for, and it may bind no port at all:

```text
restrict,port-forwarding,permitopen="localhost:22001",permitlisten="localhost:1" ssh-ed25519 AAAA... ops@laptop
```

`ssh -J` and `ssh -L` both open a local forward from the bastion to
`localhost:<port>`, so that `permitopen` is what makes
[the access command](#reaching-a-device) work. A key without it is refused,
which is the point: an operator admitted for one device cannot reach another,
and nobody reaches the bastion's own network.

`permitlisten` is the mirror image and has to be there: `port-forwarding` on a
key allows both directions, so without it an operator could bind any loopback
port on the bastion with `ssh -R`. That includes the port of a device whose
tunnel is down, and the next person to connect there would land on the
operator's forward instead of the device, with nothing but the host-key check in
between. `localhost:1` is a port nothing binds, so the direction is refused.
OpenSSH has no keyword that allows local forwarding alone.

## Rehearsing

`tests/integration/bastion.sh start` brings up a throwing-away `sshd` on the
host's loopback (port 2200): a per-device key with the same `permitlisten` and
`permitopen` restriction as above, on a much looser server configuration
(your own user, `StrictModes no`, no separate account). `bastion.sh env` prints
the four inputs for `just iso`. It is what the QEMU walkthrough in
[build.md](build.md#first-install-rehearsal) uses.
