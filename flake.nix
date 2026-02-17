{
  description = "Sandboxed Claude Code sessions with Chromium via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true; # claude-code is unfree
      };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.callPackage ./nix/backends/bubblewrap.nix { };

          # Variant with network isolation
          no-network = pkgs.callPackage ./nix/backends/bubblewrap.nix {
            network = false;
          };

          # systemd-nspawn container backend (requires sudo)
          container = pkgs.callPackage ./nix/backends/container.nix {
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = args.imports;
            });
          };

          container-no-network = pkgs.callPackage ./nix/backends/container.nix {
            network = false;
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = args.imports;
            });
          };

          # QEMU VM backend (strongest isolation)
          vm = pkgs.callPackage ./nix/backends/vm.nix {
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = args.imports;
            });
          };

          vm-no-network = pkgs.callPackage ./nix/backends/vm.nix {
            network = false;
            nixos = args: (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = args.imports;
            });
          };

          # Remote sandbox manager (Rust/Axum web dashboard)
          manager = pkgs.callPackage ./nix/manager/package.nix {
            sandboxPackages = [
              (pkgs.callPackage ./nix/backends/bubblewrap.nix { })
            ];
          };

          # Local CLI for managing remote sandboxes via SSH
          cli = pkgs.callPackage ./scripts/claude-remote.nix { };

          # Documentation site (mdBook)
          docs = pkgs.stdenv.mkDerivation {
            name = "claude-sandbox-docs";
            src = ./docs;
            nativeBuildInputs = [ pkgs.mdbook ];
            buildPhase = "mdbook build";
            installPhase = "cp -r book $out";
          };
        });

      # NixOS modules
      nixosModules.default = ./nix/modules/sandbox.nix;
      nixosModules.manager = ./nix/modules/manager.nix;

      # Checks: build all packages + NixOS VM tests
      checks = forAllSystems (system:
        self.packages.${system} // {
          manager-test = (pkgsFor system).testers.nixosTest (import ./tests/manager.nix { inherit self; });
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = [
              (pkgs.callPackage ./scripts/claude-remote.nix { })
            ] ++ (with pkgs; [
              nixd           # Nix LSP
              nil            # Alternative Nix LSP
              nixpkgs-fmt    # Nix formatter
            ]);
          };

          # Rust dev shell for the manager
          manager = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              rust-analyzer
              pkg-config
              openssl
            ];
          };
        });
    };
}
