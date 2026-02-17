# Getting Started

## Requirements

- **NixOS or Nix with flakes enabled** on Linux
- **User namespaces** for the bubblewrap backend (enabled by default on most distros)
- **X11 or Wayland** display server for bubblewrap/container backends
- **KVM** recommended for the VM backend (`/dev/kvm`)
- **`ANTHROPIC_API_KEY`** in your environment, or an existing `~/.claude` login (auto-mounted)

## Quick Start

### Bubblewrap (unprivileged)

The default package. No root required.

```bash
# Run Claude Code in a sandbox
nix run github:jhhuh/claude-code-nix-sandbox -- /path/to/project

# Drop into a shell inside the sandbox
nix run github:jhhuh/claude-code-nix-sandbox -- --shell /path/to/project
```

### systemd-nspawn container (requires sudo)

```bash
nix build github:jhhuh/claude-code-nix-sandbox#container

sudo ./result/bin/claude-sandbox-container /path/to/project

# Shell mode
sudo ./result/bin/claude-sandbox-container --shell /path/to/project
```

### QEMU VM (strongest isolation)

Claude runs on the serial console in your terminal. Chromium renders in the QEMU display window.

```bash
nix build github:jhhuh/claude-code-nix-sandbox#vm

./result/bin/claude-sandbox-vm /path/to/project

# Shell mode
./result/bin/claude-sandbox-vm --shell /path/to/project
```

## What gets forwarded

All three backends automatically forward these from your host:

- **`~/.claude`** — auth persistence (read-write)
- **`~/.gitconfig`, `~/.config/git/`, `~/.ssh/`** — git/SSH config (read-only)
- **`SSH_AUTH_SOCK`** — SSH agent forwarding
- **`ANTHROPIC_API_KEY`** — API key (if set)
- **`/nix/store`** — Nix store (read-only) + daemon socket

## Available packages

| Package | Binary | Description |
|---|---|---|
| `default` | `claude-sandbox` | Bubblewrap with network |
| `no-network` | `claude-sandbox` | Bubblewrap without network |
| `container` | `claude-sandbox-container` | systemd-nspawn with network |
| `container-no-network` | `claude-sandbox-container` | systemd-nspawn without network |
| `vm` | `claude-sandbox-vm` | QEMU VM with NAT |
| `vm-no-network` | `claude-sandbox-vm` | QEMU VM without network |
| `manager` | `claude-sandbox-manager` | Remote sandbox manager daemon |
| `cli` | `claude-remote` | CLI for remote management |

Build any package with:

```bash
nix build github:jhhuh/claude-code-nix-sandbox#<package>
```
