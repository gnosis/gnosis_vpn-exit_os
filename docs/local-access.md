# Local access over SSH

How an operator logs in to a device from its LAN and manages who may. This is
the only access an [unmanaged device](first-install.md#choose-your-setup) has,
and it works the same on a managed device, which also has a support bastion, in
hardware and in a VM.

## What the device accepts

|                            |                                                                                                                                                                                          |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| User                       | `devops` only; root cannot log in                                                                                                                                                        |
| Authentication             | SSH public key only; no SSH passwords. A console-configured device also has a `devops` password, valid on its console only ([first access on the console](#first-access-on-the-console)) |
| Privilege                  | `devops` has passwordless `sudo`                                                                                                                                                         |
| Where from                 | TCP port 22 on the wired LAN port, from private (RFC1918) source addresses: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`                                                              |
| Anything else from the LAN | ICMP echo (ping) and DHCP replies (UDP 67 -> 68 on `lan0`), plus the default gateway's SSDP answer (UDP source port 1900) while a netprobe runs; no other service is reachable           |

The source restriction, the port and the user are part of the image
(`/usr/share/gvpn-exit/iptables.rules`,
`/etc/ssh/sshd_config.d/40-gvpn-exit.conf`). What you configure is which keys
may log in: one when the installer is built, any number on the device
afterwards.

The device cannot be reached from the internet, and forwarding port 22 on the
router does not change that, because the forwarded connection arrives from a
public source address. To work on it from elsewhere, reach the LAN first (your
own VPN into that network, or a host on it to jump through), or install the
device with a [support bastion](bastion.md).

## The key in the installer

`GVPN_DEVOPS_SSH_KEY` names the public key file the installer puts into
`devops`' `authorized_keys`
([first install](first-install.md#build-it-locally)). A console-configured ISO
has no installer key; add the key shown here on the device's console instead
([below](#first-access-on-the-console)). Create a pair if you have none, and
keep the private half:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/gvpn-exit -C "you@workstation"
export GVPN_DEVOPS_SSH_KEY="$HOME/.ssh/gvpn-exit.pub"
```

- Only the first line of the file is used, and its comment is dropped.
- Accepted types: `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa` and the
  security-key types `sk-ssh-ed25519@openssh.com` and
  `sk-ecdsa-sha2-nistp256@openssh.com`.
- Without the variable the build reads `ssh_id.pub` in the repository root.

That key is the only way in after the install. If its private half is lost
before you added another key, the way back is the
[recovery stick](#when-no-key-works-any-more).

## First access on the console

A console-configured device (installed from the published ISO or one built with
`just iso-console`) has no SSH key after the install. Its first access is the
console: a keyboard and monitor (tty1) on hardware, the serial console in an
Incus VM (`just incus-console`, [Incus VM](incus.md#on-the-console)).

1. Log in as `devops` with the temporary password `gvpn-exit`. It is expired, so
   the login asks for a new one; choose it.
2. Install your public key:

   ```sh
   install -d -m 700 ~/.ssh
   cat >> ~/.ssh/authorized_keys <<'EOF'
   ssh-ed25519 AAAA... you@workstation
   EOF
   chmod 600 ~/.ssh/authorized_keys
   ```

3. Read the host key fingerprint for the first SSH connection:
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
4. Log in over SSH with your key ([first login](#first-login)).

SSH stays public-key-only, so the password works on the console only. The
console stays a way in, though: anyone at the keyboard and monitor, or with
access to the VM console, can log in as `devops` with the password chosen at the
first login, or with `gvpn-exit` until then, and has root through `sudo`. Once
your key works over SSH, lock the password:

```sh
sudo passwd -l devops
```

Key login keeps working. On a key-configured device the `devops` password is
locked from the install, and a keyboard and monitor are no way in.

## First login

Find the address the router's DHCP server gave the device (its lease table lists
it; the device answers ping), then:

```sh
ssh -i ~/.ssh/gvpn-exit devops@DEVICE_IP
```

The first connection asks you to accept the device's host key. On a
console-configured device compare it with the fingerprint read on the console.
On a key-configured device nothing shows the fingerprint beforehand, since
nobody can log in at the console, so make that first connection on a network you
trust: your own LAN, right after the install. Then record the fingerprint and
compare it whenever SSH warns that the key changed:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub    # on the device
```

The host keys are created at the first boot, so installing the device again
gives it new ones.

An entry in `~/.ssh/config` on your workstation saves the options:

```text
Host gvpn-exit
    HostName DEVICE_IP
    User devops
    IdentityFile ~/.ssh/gvpn-exit
    IdentitiesOnly yes
```

Give the device a fixed lease in the router so `DEVICE_IP` stays the same; the
device itself takes its address from DHCP only.

## Adding and replacing keys

Keys live in `/var/home/devops/.ssh/authorized_keys` (`~/.ssh/authorized_keys`
for `devops`), one public key per line. The file is device state: image updates
and rollbacks leave it alone.

Add a key, for a second workstation or another person:

```sh
echo 'ssh-ed25519 AAAA... name@host' >> ~/.ssh/authorized_keys
```

Replace a key in this order, so a mistake cannot lock you out:

1. Add the new key as above.
2. Keep the current session open and log in with the new key from a second
   terminal.
3. Only then remove the old line with an editor (`vi ~/.ssh/authorized_keys`).

Keep the file owned by `devops` with mode `0600`; `sshd`'s `StrictModes` refuses
a key file that group or others can write, or that belongs to a user other than
`devops` or root. Everyone listed there has root on the device through `sudo`,
so list people you would hand the device to.

## Day-to-day

```sh
sudo gvpn-exit-status                               # full diagnostic
ssh -L 19999:127.0.0.1:19999 gvpn-exit              # netdata at http://127.0.0.1:19999
```

netdata and the other local services listen on the device's loopback only; the
SSH forward above is how to look at them.

The `gvpn-exit-support` command manages the tunnel to a support bastion. On an
unmanaged device there is no tunnel, and the command changes nothing about LAN
access.

## When no key works any more

The [recovery stick](recovery.md) is the way back in: built from this repository
with your public keys on it, booted once on the device, it adds those keys to
`devops`. It needs no bastion. The keys it adds expire after seven days, so log
in from the LAN within that time and add a permanent key as
[above](#adding-and-replacing-keys). A console-configured device whose `devops`
password is not locked can also be reached on its console with that password.

An unmanaged device ignores the support window the stick opens; the bastion and
support port lines of its report stay empty. The stick only accepts a device
that ran `gvpn-exit-provision identity`; one that never got that far holds
nothing worth keeping, so install it again with a key you have.
