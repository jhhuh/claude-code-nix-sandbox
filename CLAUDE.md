# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**claude-code-nix-sandbox** — Pure Nix machinery for launching sandboxed Claude Code sessions with Chromium browser access. Three isolation backends with increasing strength: bubblewrap (unprivileged), systemd-nspawn (root), QEMU VM (strongest).

## Architecture

```
flake.nix              # Entry point: packages, checks, nixosModules, devShells
nix/backends/
  bubblewrap.nix       # bwrap sandbox — unprivileged, user namespaces
  container.nix        # systemd-nspawn container — requires root, full namespace isolation
  vm.nix               # QEMU VM — separate kernel, hardware virtualization
nix/modules/
  sandbox.nix          # NixOS module for declarative sandbox configuration
  manager.nix          # NixOS module for the manager systemd service
nix/manager/
  package.nix          # rustPlatform.buildRustPackage for the manager daemon
scripts/
  claude-remote.nix    # writeShellApplication CLI for remote management via SSH
manager/               # Rust/Axum web dashboard + REST API
  src/
    main.rs            # Axum router, background tasks (monitor + screenshot loops)
    state.rs           # Sandbox/ManagerState types, JSON persistence, PID reconciliation
    api.rs             # Page handlers + JSON REST API (CRUD, screenshots, metrics)
    fragments.rs       # htmx partial handlers for auto-refreshing UI fragments
    sandbox.rs         # Lifecycle: allocate display → Xvfb → tmux → backend → monitor
    display.rs         # Xvfb spawn/kill, display number allocation
    session.rs         # tmux create/check/kill
    screenshot.rs      # Xvfb capture (ImageMagick import) + VM QMP screendump
    metrics.rs         # sysinfo system metrics + Claude JSONL session parser
  templates/           # askama HTML templates (base, index, new, sandbox, fragments/)
  static/              # Vendored htmx.min.js + style.css (no build step)
```

### Sandbox Backends

All backends are `callPackage`-able functions producing `writeShellApplication` derivations. They share a common pattern: dynamic bash arrays for optional flags (display, D-Bus, GPU, auth, network).

**Bubblewrap** uses `symlinkJoin` to build PATH from packages. **Container** evaluates a NixOS config (`nixosSystem`) to get a system closure (`toplevel`), creates an ephemeral container root, and uses `setpriv` to drop from root to the real user's UID/GID (detected via `SUDO_USER`). **VM** builds a full NixOS VM with Xorg+openbox for Chromium display and serial console for claude-code interaction; shares directories via 9p.

### Remote Manager

The manager is a Rust/Axum daemon (`manager/`) that orchestrates sandboxes on a server. It starts Xvfb displays, spawns sandbox backends inside tmux sessions, captures live screenshots, and collects system + Claude session metrics. The web dashboard uses server-rendered HTML with htmx for auto-refreshing fragments (no JS build step).

`claude-remote` is a local CLI (`scripts/claude-remote.nix`) that talks to the manager over SSH (`ssh $HOST curl ...`). Commands: `create`, `list`, `attach`, `stop`, `delete`, `metrics`, `ui` (SSH tunnel for web dashboard).

State is persisted as JSON (`state.json`). On startup, the manager loads state and reconciles PIDs (marks dead sandboxes). The `package.nix` wraps the binary with ImageMagick, socat, tmux, Xvfb, and sandbox backends on PATH.

## Common Commands

```bash
# Sandbox backends
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

# Remote manager
nix build .#manager                       # Build manager daemon
nix build .#cli                           # Build claude-remote CLI
MANAGER_LISTEN=127.0.0.1:3001 ./result/bin/claude-sandbox-manager  # Run locally
claude-remote help                        # CLI usage (available in devShell)
claude-remote create test bubblewrap /tmp/test  # Create sandbox (needs CLAUDE_REMOTE_HOST)
claude-remote list                        # List sandboxes
claude-remote attach <id>                 # Attach to tmux session
claude-remote ui                          # SSH tunnel for web dashboard
```

## Conventions

- **Pure Nix only**: no shell/Python wrappers for orchestration
- **One backend per file** in `nix/backends/`
- **Chromium from nixpkgs**: always `pkgs.chromium` inside the sandbox
- **claude-code is unfree**: `config.allowUnfree = true` in flake.nix
- **Backends are callPackage-able**: called via `pkgs.callPackage` in flake.nix
- **NixOS modules**: `sandbox.nix` as `nixosModules.default`, `manager.nix` as `nixosModules.manager`
- **Manager is Rust/Axum**: axum 0.7, askama 0.12, tower-http 0.5, sysinfo for metrics
- **Manager static files**: vendored htmx + CSS, no npm/build step; askama compiles templates into the binary
- **CLI uses SSH**: all API calls via `ssh $HOST curl ...`, no direct HTTP from laptop


## Skill Files

Non-obvious patterns discovered during development — read before modifying related code:

- `artifacts/skills/bubblewrap-dynamic-bash-arrays-for-optional-flags.md — bash arrays for conditional bwrap/nspawn flags`
- `artifacts/skills/nspawn-privilege-drop-without-pam.md — why `setpriv` instead of `su`/`runuser` in the container backend`
- `artifacts/skills/nixos-qemu-vm-serial-console-setup.md — console order, getty autologin, and tty guard for the VM backend`
- `artifacts/skills/nix-daemon-socket-forwarding-in-sandboxes.md — rw socket bind + `NIX_REMOTE=daemon` for nix inside sandboxes`
- `artifacts/skills/ssh-agent-forwarding-into-sandboxes.md — socket + env var + openssh + git config forwarding`
- `artifacts/skills/sudo-aware-uid-detection-for-containers.md — dynamic UID/GID under sudo for file ownership`
- `artifacts/skills/ssh-remote-cli-printf-q-escaping.md — printf '%q' for SSH argument escaping`
- `artifacts/skills/nix-writeShellApplication-escaping-and-shellcheck.md — `''${` escaping, SC2155/SC2029, ShellCheck-as-error in writeShellApplication`
