{
  description = "gvpn-exit-os: GnosisVPN exit node appliance OS (Fedora IoT bootc)";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # Foundry's `cast`, which the hoprd v4-to-v5 migration helper calls; the
  # devshell carries it so the helper's cast invocations can be run by hand.
  # The `stable` branch tracks Foundry releases; keep it on FOUNDRY_VERSION
  # of image/versions.env.
  inputs.foundry.url = "github:shazow/foundry.nix/stable";
  inputs.foundry.inputs.nixpkgs.follows = "nixpkgs";
  inputs.foundry.inputs.flake-utils.follows = "flake-utils";

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      foundry,
    }:
    flake-utils.lib.eachSystem
      [
        # image, disk and VM flows
        "x86_64-linux"
        # tests, linting and recovery stick images on a Linux workstation or
        # server; the QEMU harness and OVMF are x86-only
        "aarch64-linux"
        # the unit suites, linting, check-pins, promote and the recovery stick
        # image; no Podman builder, KVM or OVMF, so image, disk and USB work
        # needs a Linux container host
        "aarch64-darwin"
        "x86_64-darwin"
      ]
      (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib stdenv;
        in
        {
          devShells.default = pkgs.mkShell (
            {
              nativeBuildInputs = [
                # unit tests and linting
                pkgs.bats
                pkgs.shellcheck
                pkgs.just
                pkgs.jq
                pkgs.gnupg
                pkgs.curl
                pkgs.ipcalc
                # image publishing
                pkgs.skopeo
                pkgs.cosign
                pkgs.oras
                # cast, as the migration helper uses it on the device
                foundry.defaultPackage.${system}
                # SSH to the VM and the support bastion
                pkgs.openssh
                # the recovery stick: partitioning and formatting, and the
                # flashable image built without root or loop devices
                pkgs.gptfdisk
                pkgs.dosfstools
                pkgs.mtools
                pkgs.xz
              ]
              # The scripts and tests are written for the appliance's Linux
              # userland. On Darwin the GNU tools they call (readlink -f,
              # stat -c, flock, sed -i, sha256sum) come from the devshell
              # instead of the host.
              ++ lib.optionals stdenv.isDarwin [
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnused
                pkgs.gnugrep
                pkgs.gawk
                pkgs.util-linux
              ]
              # The VM harness needs KVM, OVMF and swtpm, and the integration
              # checks call `ip`; Darwin has none of them, and OVMF is x86-only.
              ++ lib.optionals stdenv.isLinux [ pkgs.iproute2 pkgs.swtpm pkgs.xorriso ]
              ++ lib.optionals (stdenv.isLinux && stdenv.isx86_64) [
                pkgs.qemu_kvm
                pkgs.OVMF.fd
              ];
            }
            // lib.optionalAttrs (stdenv.isLinux && stdenv.isx86_64) {
              OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
              OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
            }
          );

          formatter = pkgs.nixfmt-rfc-style;
        }
      );
}
