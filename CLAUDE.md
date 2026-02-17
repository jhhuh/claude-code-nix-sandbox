# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-code-nix-sandbox** — Pure Nix machinery for launching sandboxed Claude Code sessions with Chromium browser access. Two isolation backends: bubblewrap (unprivileged) and systemd-nspawn (root, stronger isolation).

## Architecture

```
flake.nix              # Entry point: packages (default, no-network, container, container-no-network), devShell
nix/backends/
  bubblewrap.nix       # bwrap sandbox — unprivileged, user namespaces
  container.nix        # systemd-nspawn container — requires root, full namespace isolation
```

Both backends are `callPackage`-able functions producing `writeShellApplication` derivations. They share a common pattern: dynamic bash arrays for optional flags (display, D-Bus, GPU, auth, network).

**Bubblewrap** uses `symlinkJoin` to build PATH from packages. **Container** evaluates a NixOS config (`nixosSystem`) to get a system closure (`toplevel`), creates an ephemeral container root, and uses `setpriv` to drop from root to uid 1000.

## Common Commands

```bash
nix build                                 # Build default (bubblewrap)
nix build .#container                     # Build nspawn container
./result/bin/claude-sandbox <dir>         # Run sandboxed Claude Code
./result/bin/claude-sandbox --shell <dir> # Shell inside sandbox
sudo ./result/bin/claude-sandbox-container <dir>         # Container mode
sudo ./result/bin/claude-sandbox-container --shell <dir> # Container shell
```

## Conventions

- **Pure Nix only**: no shell/Python wrappers for orchestration
- **One backend per file** in `nix/backends/`
- **Chromium from nixpkgs**: always `pkgs.chromium` inside the sandbox
- **claude-code is unfree**: `config.allowUnfree = true` in flake.nix
- **Backends are callPackage-able**: called via `pkgs.callPackage` in flake.nix

## Skill Files

Non-obvious patterns discovered during development — read before modifying related code:

- `artifacts/skills/bubblewrap-dynamic-bash-arrays-for-optional-flags.md — bash arrays for conditional bwrap/nspawn flags`
- `artifacts/skills/nspawn-privilege-drop-without-pam.md — why `setpriv` instead of `su`/`runuser` in the container backend`
- `artifacts/skills/nixos-qemu-vm-serial-console-setup.md — console order, getty autologin, and tty guard for the VM backend`
