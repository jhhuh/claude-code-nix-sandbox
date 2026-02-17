# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-code-nix-sandbox** — Pure Nix machinery for launching sandboxed Claude Code sessions with Chromium browser access. Three isolation backends with increasing strength: bubblewrap (unprivileged), systemd-nspawn (root), QEMU VM (strongest).

## Architecture

```
flake.nix              # Entry point: packages, checks, nixosModules, devShell
nix/backends/
  bubblewrap.nix       # bwrap sandbox — unprivileged, user namespaces
  container.nix        # systemd-nspawn container — requires root, full namespace isolation
  vm.nix               # QEMU VM — separate kernel, hardware virtualization
nix/modules/
  sandbox.nix          # NixOS module for declarative configuration
```

All backends are `callPackage`-able functions producing `writeShellApplication` derivations. They share a common pattern: dynamic bash arrays for optional flags (display, D-Bus, GPU, auth, network).

**Bubblewrap** uses `symlinkJoin` to build PATH from packages. **Container** evaluates a NixOS config (`nixosSystem`) to get a system closure (`toplevel`), creates an ephemeral container root, and uses `setpriv` to drop from root to the real user's UID/GID (detected via `SUDO_USER`). **VM** builds a full NixOS VM with Xorg+openbox for Chromium display and serial console for claude-code interaction; shares directories via 9p.

## Common Commands

```bash
nix build                                 # Build default (bubblewrap)
nix build .#container                     # Build nspawn container
nix build .#vm                            # Build QEMU VM
nix flake check                           # Evaluate + build all packages
./result/bin/claude-sandbox <dir>         # Run sandboxed Claude Code
./result/bin/claude-sandbox --shell <dir> # Shell inside sandbox
sudo ./result/bin/claude-sandbox-container <dir>         # Container mode
sudo ./result/bin/claude-sandbox-container --shell <dir> # Container shell
./result/bin/claude-sandbox-vm <dir>      # VM mode
./result/bin/claude-sandbox-vm --shell <dir>  # VM shell
```

## Conventions

- **Pure Nix only**: no shell/Python wrappers for orchestration
- **One backend per file** in `nix/backends/`
- **Chromium from nixpkgs**: always `pkgs.chromium` inside the sandbox
- **claude-code is unfree**: `config.allowUnfree = true` in flake.nix
- **Backends are callPackage-able**: called via `pkgs.callPackage` in flake.nix
- **NixOS module** in `nix/modules/sandbox.nix`, exposed as `nixosModules.default`


## Skill Files

Non-obvious patterns discovered during development — read before modifying related code:

- `artifacts/skills/bubblewrap-dynamic-bash-arrays-for-optional-flags.md — bash arrays for conditional bwrap/nspawn flags`
- `artifacts/skills/nspawn-privilege-drop-without-pam.md — why `setpriv` instead of `su`/`runuser` in the container backend`
- `artifacts/skills/nixos-qemu-vm-serial-console-setup.md — console order, getty autologin, and tty guard for the VM backend`
- `artifacts/skills/nix-daemon-socket-forwarding-in-sandboxes.md — rw socket bind + `NIX_REMOTE=daemon` for nix inside sandboxes`
- `artifacts/skills/ssh-agent-forwarding-into-sandboxes.md — socket + env var + openssh + git config forwarding`
- `artifacts/skills/sudo-aware-uid-detection-for-containers.md — dynamic UID/GID under sudo for file ownership`
