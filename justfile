# gvpn-exit-os: GnosisVPN exit node appliance OS (Fedora IoT bootc)
# Run recipes inside the devshell: `nix develop -c just <recipe>`.
set shell := ["bash", "-euo", "pipefail", "-c"]
# Recipes that forward their arguments (vm-ssh) need them as positional
# parameters, so that ssh sees -i and friends as options instead of one word.
set positional-arguments := true

image_tag := "localhost/gvpn-exit-os:dev"
ssh_key := env_var_or_default("GVPN_DEVOPS_SSH_KEY", "ssh_id.pub")
# An empty GVPN_INSTALL_DISK is the same as an unset one.
install_disk := if env_var_or_default("GVPN_INSTALL_DISK", "") == "" { "auto" } else { env_var_or_default("GVPN_INSTALL_DISK", "auto") }
channel := "canary"

# list recipes
default:
    @just --list

# unit tests (bats) and shellcheck
test: lint
    bats tests/unit

# shellcheck every shell script shipped or used by the build
lint:
    shellcheck -x -P image/rootfs/usr/libexec/gvpn-exit \
      image/rootfs/usr/libexec/gvpn-exit/*.sh image/rootfs/usr/bin/* \
      image/rootfs/usr/lib/greenboot/check/*/*.sh image/rootfs/usr/lib/greenboot/*.d/*.sh \
      image/rootfs/usr/lib/NetworkManager/dispatcher.d/* \
      image/build/*.sh image/bib/*.sh image/recovery/*.sh image/recovery/modules.d/*/*.sh \
      tools/*.sh tests/integration/*.sh

# verify every pinned image reference still resolves (needs network)
check-pins:
    tools/check-pins.sh

# move every pinned image reference to the newest one its tag offers (needs network; review and PR the diff)
update-pins:
    tools/update-pins.sh

# build the OS image into the builder's container storage
build:
    image/build/configure-image.sh
    GVPN_IMAGE_VERSION="$(git describe --tags --always --dirty)" tools/builder.sh tools/build-image.sh {{image_tag}}

# One installer serves hardware and an Incus VM. The devops key is always
# included; the bastion tunnel inputs GVPN_BASTION, GVPN_SUPPORT_PORT,
# GVPN_ENROLL_KEY and GVPN_BASTION_KNOWN_HOSTS (tools/render-bib-config.sh)
# make it a managed installer when given all together, without them it is
# unmanaged. The installer picks the device's only internal disk;
# GVPN_INSTALL_DISK pins one (nvme0n1, sda, ...) when there is more than one.
# unattended installer ISO (wipes the install disk; bastion inputs all together or not at all)
iso: build (_disk "iso" install_disk "0")

# Configured from its console: no SSH key, the operator adds their own after
# the first console login (the VM console, or keyboard and monitor on
# hardware). This is what CI publishes.
# unattended installer ISO configured from its console (wipes the install disk)
iso-console: build (_disk "iso" install_disk "1")

# console-configured installer ISO from the image already built (CI after `just build`)
iso-console-only: (_disk "iso" install_disk "1")

# stable moves only through `just promote`
# push the built image signed (GVPN_COSIGN_KEY, default ./cosign.key) and move canary to it
publish:
    tools/publish.sh {{quote(channel)}}

# push the built image signed (GVPN_COSIGN_KEY, default ./cosign.key) without moving a channel
push:
    tools/publish.sh --no-channel

# promote an existing published version to a channel (canary or stable)
promote version channel:
    tools/promote.sh {{quote(version)}} {{quote(channel)}}

# qcow2 disk for QEMU
qcow2: build (_disk "qcow2" install_disk "0")

# render the bib config on the host (key files may live outside the repo),
# then build the disk in the builder; the rendered config never outlives it.
# tools/build-disk.sh writes the version and target sidecars of an ISO.
_disk kind disk console:
    mkdir -p output
    config="$(mktemp -p output .bib-{{kind}}-XXXXXX.toml)"; \
      trap 'rm -f "${config}"' EXIT; \
      GVPN_CONSOLE_ACCESS={{quote(console)}} GVPN_INSTALL_DISK={{quote(disk)}} \
        tools/render-bib-config.sh {{quote(kind)}} {{quote(ssh_key)}} > "${config}"; \
      SOURCE_TAG={{image_tag}} tools/builder.sh tools/build-disk.sh {{quote(kind)}} "${config}" {{quote(channel)}}

# publish the installer ISO signed and move iso-canary to it
publish-iso version="":
    tools/publish-iso.sh {{quote(version)}}

# push the installer ISO signed without moving the iso channel
push-iso version="":
    tools/publish-iso.sh --no-channel {{quote(version)}}

# move iso-canary to an already published version (no rebuild)
tag-iso version:
    tools/publish-iso.sh --tag-only {{quote(version)}}

# pull a published installer ISO (version or canary) into output/published-iso and print its path
pull-iso ref:
    tools/pull-iso.sh {{quote(ref)}}

# create an Incus VM and boot the installer in it (UEFI, vTPM, 64 GiB);
# ISO="" builds one with `just iso`, otherwise installs the given ISO
incus-install iso="":
    if [[ -n {{quote(iso)}} ]]; then \
      tools/incus.sh install {{quote(iso)}}; \
    else \
      just iso; \
      tools/incus.sh install output/iso/bootiso/install.iso; \
    fi

# pull a published installer ISO and install it in a fresh VM (no local build)
incus-install-published ref:
    iso="$(tools/pull-iso.sh {{quote(ref)}})"; \
      tools/incus.sh install "${iso}"

# detach the installer and boot the installed Incus VM
incus-run:
    tools/incus.sh run

# ssh into the running Incus VM as devops (pass -i if your agent has no key)
incus-ssh *args:
    tools/incus.sh ssh "$@"

# attach to the Incus VM's serial console (leave it with Ctrl-a q)
incus-console:
    tools/incus.sh console

# delete the Incus VM, its disk and its vTPM
incus-destroy:
    tools/incus.sh destroy

# install the ISO into a fresh QEMU VM (nvme disk, swtpm, OVMF)
vm-install:
    tools/vm.sh install output/iso/bootiso/install.iso

# boot the installed QEMU VM; ssh with `just vm-ssh`
vm-run:
    tools/vm.sh run

# ssh into the running QEMU VM as devops
vm-ssh *args:
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null devops@127.0.0.1 "$@"

# integration tests against the running QEMU VM (unprovisioned|enroll|provision|provisioned|address|update)
test-integration phase:
    tests/integration/run.sh {{quote(phase)}}

# ISO="" writes the built output/iso/bootiso/install.iso (or GVPN_ISO),
# otherwise the given one, such as a pulled output/published-iso/install.iso
# write the installer ISO to a whole USB disk (DEVICE like /dev/sdX; asks sudo)
usb device iso="":
    @printf 'Writing %s to %s - all data on it is lost.\n' {{quote(if iso == "" { env_var_or_default("GVPN_ISO", "output/iso/bootiso/install.iso") } else { iso })}} {{quote(device)}}
    @read -r -p "Type the device path again to confirm: " confirm && [ "$confirm" = {{quote(device)}} ]
    if [[ -n {{quote(iso)}} ]]; then export GVPN_ISO={{quote(iso)}}; fi; \
      tools/write-usb.sh {{quote(device)}}

# build the recovery stick image (output/recovery/BOOTX64.EFI; budget in image/recovery/versions.env)
recovery-build:
    tools/builder.sh tools/build-recovery.sh

# pack the recovery stick into output/recovery/gvpn-recovery-<version>.img.xz for someone on site to flash
recovery-image keys="":
    tools/recovery-image.sh {{quote(keys)}}

# write the recovery stick for any appliance (DEVICE like /dev/sdX; asks sudo)
recovery-usb device:
    @printf 'Writing the recovery stick to %s - all data on it is lost.\n' {{quote(device)}}
    @read -r -p "Type the device path again to confirm: " confirm && [ "$confirm" = {{quote(device)}} ]
    sudo env "PATH=$PATH" tools/recovery-usb.sh {{quote(device)}}
