# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-code-nix-sandbox** — Pure Nix machinery for launching sandboxed Claude Code sessions with Chromium browser access. Supports multiple isolation backends (NixOS VM, container, bubblewrap) with Chromium provided from nixpkgs inside the sandbox.

## Architecture

```
flake.nix              # Entry point: devShell, packages, NixOS modules
nix/
  lib/                 # Shared Nix utility functions
  modules/             # NixOS module(s) for sandbox configuration
  backends/            # Sandbox backend implementations
    vm.nix             # QEMU/microvm-based NixOS VM
    container.nix      # nixos-container / systemd-nspawn
    bubblewrap.nix     # bubblewrap (bwrap) lightweight sandbox
  profiles/            # Pre-built sandbox profiles (e.g. claude-code + chromium)
```

Everything is pure Nix — no shell/Python wrapper scripts. The flake exposes packages and NixOS modules that configure and launch sandboxed environments.

## Development

### Prerequisites

- Nix with flakes enabled (`nix.settings.experimental-features = ["nix-command" "flakes"]`)
- direnv (optional, `.envrc` auto-loads devShell)

### Common Commands

```bash
direnv allow                   # Load devShell (after flake.nix changes)
nix flake check                # Validate flake outputs and run checks
nix build                      # Build default package
nix build .#<backend>          # Build a specific backend
nix flake show                 # List all flake outputs
```

## Conventions

- **Pure Nix only**: no shell scripts, Python, or other languages for orchestration. Helper logic goes in `nix/lib/`.
- **One backend per file** in `nix/backends/`. Each backend exports a NixOS module or a derivation.
- **Chromium from nixpkgs**: always use `pkgs.chromium` (or `pkgs.ungoogled-chromium`) inside the sandbox — never forward host browser.
- **Profiles** in `nix/profiles/` compose a backend + packages (claude-code, chromium, etc.) into a ready-to-run sandbox config.
