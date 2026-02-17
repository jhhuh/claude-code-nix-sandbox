# Nix: Overlay Injection into nixosSystem Calls

## Problem

When using a flake overlay to shadow a package (e.g., `pkgs.claude-code` from an external flake), the overlay is applied to `pkgsFor` in your flake but **not** automatically to `nixpkgs.lib.nixosSystem` evaluations used by container/VM backends.

Each `nixosSystem` call creates its own `pkgs` instance. Without the overlay, `pkgs.claude-code` inside the NixOS evaluation resolves to the upstream nixpkgs version — silently using the wrong package.

## Solution

Inject the overlay into every `nixosSystem` call via a `nixpkgs.overlays` module:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
    claude-code-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, claude-code-nix, ... }:
    let
      # Main package set — overlay applied here
      pkgsFor = nixpkgs.legacyPackages.${system}.extend claude-code-nix.overlays.default;

      # Helper for nixosSystem calls — overlay injected via module
      nixos = args: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          { nixpkgs.overlays = [ claude-code-nix.overlays.default ]; }
        ] ++ args.modules;
      };
    in {
      # Bubblewrap: uses pkgsFor directly (overlay works via callPackage)
      packages.bubblewrap = pkgsFor.callPackage ./backend.nix {};

      # Container/VM: uses nixosSystem (overlay must be injected)
      packages.container = (nixos { modules = [ ./container-module.nix ]; }).config.system.build.toplevel;
    };
}
```

## Key Points

- `inputs.nixpkgs.follows = "nixpkgs"` prevents duplicate nixpkgs evaluations
- The overlay module must be in the `modules` list, not passed via `specialArgs`
- Backend `.nix` files don't change — they still reference `pkgs.claude-code`
- This pattern applies to **any** flake overlay used inside `nixosSystem`

## Symptoms When Missing

- Container/VM uses outdated or wrong package version
- No build error — the package name resolves, just to the wrong derivation
- Debugging requires comparing store paths between `pkgsFor.claude-code` and the NixOS-evaluated `pkgs.claude-code`

## References

- `flake.nix` — overlay injection in `nixos` helper
- `artifacts/devlog.md` — "Switch claude-code to sadjow/claude-code-nix" entry (2026-02-18)
