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
  # `nix fmt`: deno fmt for the Markdown, nixfmt for the Nix files.
  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  # The pre-commit hook that runs the `nix fmt` formatters on staged files; the
  # devshell installs it into .git/hooks.
  inputs.git-hooks.url = "github:cachix/git-hooks.nix";
  inputs.git-hooks.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      foundry,
      treefmt-nix,
      git-hooks,
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
          treefmt =
            (treefmt-nix.lib.evalModule pkgs {
              projectRootFile = "flake.nix";
              programs.deno.enable = true;
              programs.deno.includes = [ "*.md" ];
              programs.nixfmt.enable = true;
            }).config.build.wrapper;
          # Scans the commits a push sends. pre-commit names them by
          # PRE_COMMIT_FROM_REF..PRE_COMMIT_TO_REF, and passes no range when the
          # pushed history has no commit on the remote yet; then the whole
          # history is scanned.
          gitleaks-push = pkgs.writeShellApplication {
            name = "gitleaks-push";
            runtimeInputs = [
              pkgs.gitleaks
              pkgs.git
            ];
            text = ''
              if [[ -n "''${PRE_COMMIT_FROM_REF:-}" && -n "''${PRE_COMMIT_TO_REF:-}" ]]; then
                exec gitleaks git --redact --verbose \
                  --log-opts="''${PRE_COMMIT_FROM_REF}..''${PRE_COMMIT_TO_REF}"
              fi
              exec gitleaks git --redact --verbose
            '';
          };
          # git-hooks.nix's flake leaves x86_64-darwin out of its lib; its own
          # entry point still builds the hooks there from our nixpkgs.
          git-hooks-lib =
            git-hooks.lib.${system} or (import "${git-hooks}/nix" {
              inherit nixpkgs system;
              isFlakes = true;
            });
          pre-commit = git-hooks-lib.run {
            src = ./.;
            hooks.treefmt.enable = true;
            hooks.treefmt.package = treefmt;
            hooks.gitleaks-push = {
              enable = true;
              name = "gitleaks";
              entry = lib.getExe gitleaks-push;
              pass_filenames = false;
              # A secret added and removed again within the pushed commits
              # leaves no changed file, and pre-commit would skip the hook.
              always_run = true;
              stages = [ "pre-push" ];
            };
          };
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
              ++ lib.optionals stdenv.isLinux [
                pkgs.iproute2
                pkgs.swtpm
                pkgs.xorriso
              ]
              ++ lib.optionals (stdenv.isLinux && stdenv.isx86_64) [
                pkgs.qemu_kvm
                pkgs.OVMF.fd
              ]
              ++ pre-commit.enabledPackages;
              # Installs the pre-commit hook into .git/hooks.
              inherit (pre-commit) shellHook;
            }
            // lib.optionalAttrs (stdenv.isLinux && stdenv.isx86_64) {
              OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";
              OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd";
            }
          );

          formatter = treefmt;
        }
      );
}
