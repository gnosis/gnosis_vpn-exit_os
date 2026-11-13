# Run the appliance in an Incus VM

An Incus VM is the VM target of the [first install](first-install.md#choose-your-setup):
an alternative to a SER8 or A8, not only a test harness. The guest runs the
same image from the same installer ISO, with the same provisioning, checks and
services, managed or unmanaged; Incus supplies the UEFI firmware, the TPM and
the disk. Sized as recommended, the VM is intended to serve clients with the
same capacity as a dedicated appliance. Follow
[first-install.md](first-install.md) for the runbook; this page covers what
the VM changes. Acceptance still follows
[the acceptance gate](first-install.md#7-acceptance-gate).

## What differs from hardware

| | Hardware | Incus VM |
|---|---|---|
| Install disk | The internal NVMe disk, picked by the installer | The root disk, `/dev/sda` (Incus' default virtio-scsi), picked by the installer |
| Installer media | A USB stick (`just usb`) | A disk device Incus attaches (`just incus-install`) |
| Firmware | UEFI, Secure Boot off | UEFI, Secure Boot off (`incus` sets `security.secureboot=false`; the installer ISO is not signed) |
| TPM | firmware fTPM | Incus vTPM device `tpm`; provisioning seals into it |
| Network | 2.5GbE port, DHCP LAN | virtio NIC, DHCP on an Incus bridge; the image still renames it `lan0` |
| SSH source | an RFC1918 LAN address | the bridge address (keep the bridge's IPv4 range RFC1918) |
| Console | keyboard and monitor (tty1) | the serial console (`just incus-console`); a console-configured installer enables the serial getty only in a VM |
| First access | the installer's SSH key, or the console for a console-configured ISO; the bastion when managed | the same |
| Resources | CPU, RAM and NVMe of the appliance | **at least 8 vCPUs, 16 GiB RAM** and a 64 GiB disk; size the host so the guest keeps them |
| Power/CPU policy | firmware Always On, performance mode | supplied by the host; a VM often exposes no cpufreq policy, so `gvpn-exit-status` reports the governor as `n/a` |

The VM is an appliance workload on a virtual host: it has no Always On
firmware setting, its uplink and public IPv4 are the host's (or its router's),
and a deleted VM takes its vTPM and therefore its sealed identity with it. The
capacity measurement still runs against the virtual link. Give the VM the
resources above and a stable host; a shared or overcommitted host changes the
throughput the exit can offer.

## Prerequisites

On a Linux host with KVM:

- Plan for **at least 8 CPU cores and 16 GiB RAM for the VM**, plus room for
  Incus and the host. Below that the guest still boots, but it is below the
  recommended exit capacity. The default VM size in `tools/incus.sh` is 8
  vCPUs, 16 GiB RAM and a 64 GiB disk.
- Incus is installed and initialised (`incus admin init`) with a managed
  bridge and a storage pool. The examples use the default bridge `incusbr0`.
- Your user is in the `incus-admin` group (or you run the `incus` commands as
  root). The devshell does not ship Incus; it is a host tool.
- The profile's bridge offers DHCP in an RFC1918 range. Do not use
  `172.30.0.0/24` (it contains the session target `172.30.0.1`) or
  `10.128.0.0/24` (the WireGuard pool). Check with:

  ```sh
  incus network show incusbr0 | grep ipv4.address
  ```

- The host firewall lets DHCP and DNS from the bridge reach Incus' dnsmasq.
  A firewall that drops input from untrusted interfaces leaves the guest
  without a lease, and `incus-run` reports no IPv4 address. On NixOS, set
  `networking.firewall.trustedInterfaces = [ "incusbr0" ];`.

- The inputs for the installer you use
  ([getting the installer](first-install.md#3-get-the-installer)):
  `GVPN_IMAGE_REPO` and `GVPN_COSIGN_PUB` in every case; for a key-configured
  build also `GVPN_DEVOPS_SSH_KEY`, whose private half you keep for
  `VM_SSH_KEY`; for a managed build also the four bastion inputs.

Run the commands in the devshell, like every other recipe. The `incus`
commands themselves are taken from the host `PATH`.

## Create the VM

Pick the installer, then create the VM from it:

```sh
nix develop -c just incus-install                       # builds with just iso first
nix develop -c just incus-install ISO                   # an ISO you built or pulled
nix develop -c just incus-install-published VERSION     # pulls the published ISO
```

A local build is at `output/iso/bootiso/install.iso`, for example after
`just iso-console`.

`incus-install-published` pulls with `just pull-iso` (signature verified
against `GVPN_COSIGN_PUB`, checksums of the ISO, its version and its target)
into `output/published-iso/`; to inspect
the download first, run `just pull-iso VERSION` and then
`just incus-install output/published-iso/install.iso`. Use `canary` instead
of `VERSION` once `iso-canary` points at it; a version that is not promoted
yet installs a VM that then updates to the older canary image
([the published ISO](first-install.md#pull-the-published-iso)).

`incus-install` creates the VM `gvpn-exit`, adds a vTPM and a second disk for
the ISO, and boots the installer on the console. The default VM has the
recommended **8 vCPUs, 16 GiB of memory** and a 64 GiB root disk; override
them with `GVPN_INCUS_CPUS`, `GVPN_INCUS_MEMORY` and `GVPN_INCUS_DISK_SIZE`
(GiB or MiB, in Incus size syntax). Do not go below 8 vCPUs and 16 GiB for a
production exit. `GVPN_INCUS_VM` names another instance; `GVPN_INCUS_IP_WAIT`
is how many seconds `incus-run` waits for the guest's DHCP address (default
60, `0` for no wait).

The installer is unattended and reboots when it is done. Leave the console
with `Ctrl-a q`, then remove the installer and boot the installed disk:

```sh
nix develop -c just incus-run
```

`incus-run` stops the installer, removes the `install` disk device and starts
the VM again. The installed VM follows `<GVPN_IMAGE_REPO>:canary` for updates
unless its ISO was built with `channel=stable`.

The VM has no Incus agent, so `incus exec` does not work. Use SSH or
`just incus-console` (`Ctrl-a q` leaves it). If `just incus-ssh` reports no
IPv4 address, check `incus list gvpn-exit`, the bridge's DHCP range and that
the host firewall lets the bridge's DHCP through (see the prerequisites).

To start over, `just incus-destroy` deletes the VM, its disk and its vTPM;
the next `just incus-install` gets a new virtual TPM and therefore a new
identity.

## First access

### With a key in the installer

A key-configured ISO (`just iso`) installs `GVPN_DEVOPS_SSH_KEY`. Reach the VM
with the matching private key:

```sh
export VM_SSH_KEY="$HOME/.ssh/id_ed25519"
nix develop -c just incus-ssh
```

`incus-ssh` looks up the address Incus learned from DHCP and connects as
`devops`; `VM_SSH_KEY` supplies `-i`, or pass it to `just incus-ssh` yourself.

### On the console

A console-configured ISO (the published one, or `just iso-console`) installs
no SSH key and enables a serial getty in the VM. After `just incus-run`,
attach to the console:

```sh
nix develop -c just incus-console
# or: incus console gvpn-exit
```

Log in as `devops` with `gvpn-exit`, choose a new password and install your
public key as [local access](local-access.md#first-access-on-the-console)
describes, then leave the console with `Ctrl-a q` and continue with
`just incus-ssh` as above. Anyone with access to the VM console can log in
with that password; lock it with `sudo passwd -l devops` once your key works.

## Provision and check

The provisioning and check steps are the same as on hardware
([first-install.md](first-install.md#5-provision)), just over SSH:

```sh
nix develop -c just incus-ssh sudo gvpn-exit-provision identity
# create and fund the Safe and module for the printed node address
nix develop -c just incus-ssh sudo gvpn-exit-provision finalize \
  --safe-address 0x... --module-address 0x... \
  --blokli-url https://blokli.example.org --location "Incus, XX"
nix develop -c just incus-ssh sudo systemctl reboot
nix develop -c just incus-run
nix develop -c just incus-ssh sudo gvpn-exit-status
```

An unmanaged VM needs no bastion. A managed VM dials its bastion from the
guest ([managed setup in Incus](#managed-setup-in-incus)).

The integration phases can target the VM too, because the SSH checks take the
guest address from `VM_SSH_HOST`:

```sh
export VM_SSH_HOST="$(nix develop -c tools/incus.sh ip)"
export VM_SSH_PORT=22
nix develop -c just test-integration unprovisioned
# ... enroll/provision/provisioned/address as in build.md
```

Without `GVPN_BASTION` in the environment, `unprovisioned` checks a LAN-only
device, like one from the published ISO: no enrollment files and
`enroll-tunnel.service` off. With the bastion inputs exported, as in
[Managed setup in Incus](#managed-setup-in-incus), it checks the installer's
enrollment files and the running tunnel instead.

`VM_SSH_HOST` is a snapshot of the DHCP address. Re-resolve it after a reboot
if the VM comes back on another lease. The bastion phases still use the
workstation's loopback for the reverse port (`VM_BASTION_SSH_HOST` changes
that).

## Managed setup in Incus

A managed VM is installed like managed hardware: build its per-device ISO
with the four bastion inputs and `just iso`
([build it locally](first-install.md#build-it-locally)), then install that
file with `just incus-install output/iso/bootiso/install.iso`. The bastion
must be reachable from the guest. After provisioning, reach the VM through
the bastion as [bastion.md](bastion.md#reaching-a-device) shows, with
operator keys admitted as described in
[bastion.md](bastion.md#operators-keys).

### Rehearsal with the throwaway bastion

For the throwaway bastion in this repository, use the Incus bridge's host
address instead of QEMU's `10.0.2.2`, and let its `sshd` listen on that
address:

```sh
BRIDGE_IP="$(incus network get incusbr0 ipv4.address | cut -d/ -f1)"
export BASTION_LISTEN_ADDR="${BRIDGE_IP}"
export BASTION_ADDRESS="${BRIDGE_IP}"

# Only when output/bastion was created for QEMU with 10.0.2.2/loopback:
rm -rf output/bastion
nix develop -c tests/integration/bastion.sh start
eval "$(nix develop -c tests/integration/bastion.sh env)"   # GVPN_BASTION=ssh://...
nix develop -c just incus-install
```

After provisioning, reach the VM through the throwaway bastion on the
workstation's loopback. The reverse port is already there; the operator key is
not one of the bastion's restricted device keys, so no `ssh -J` is needed:

```sh
ssh -p "${GVPN_SUPPORT_PORT}" devops@127.0.0.1
```

A real bastion is reached with `ssh -J` as its runbook shows. Stop the
throwaway bastion when the rehearsal is over:

```sh
nix develop -c tests/integration/bastion.sh stop
```

## Alternative disk buses

The installer picks the VM's only internal disk itself, so a root disk on
`io.bus=virtio-blk` (`/dev/vda`) needs no special ISO. `tools/incus.sh install`
checks the ISO's target sidecar and accepts an ISO with `disk=auto` or one
pinned to the VM's disk. `GVPN_INCUS_INSTALL_DISK` names that disk (default
`sda`) and only matters for an ISO built with `GVPN_INSTALL_DISK`:

```sh
GVPN_INSTALL_DISK=vda nix develop -c just iso
GVPN_INCUS_INSTALL_DISK=vda nix develop -c just incus-install output/iso/bootiso/install.iso
```

`GVPN_INSTALL_DISK` is validated by `tools/render-bib-config.sh`; the
installer still wipes exactly that disk without asking.
