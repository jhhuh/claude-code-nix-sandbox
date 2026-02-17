# claude-code-nix-sandbox

Launch sandboxed [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code) sessions with Chromium using Nix.

Claude Code runs inside an isolated sandbox with filesystem isolation, display forwarding, and a Chromium browser — all from nixpkgs. Two backends available: [bubblewrap](https://github.com/containers/bubblewrap) (unprivileged) and [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) (root, stronger isolation).

## Quick Start

### Bubblewrap (unprivileged)

```bash
# Run Claude Code in a sandbox
nix run github:jhhuh/claude-code-nix-sandbox -- /path/to/project

# Drop into a shell inside the sandbox
nix run github:jhhuh/claude-code-nix-sandbox -- --shell /path/to/project
```

### systemd-nspawn container (requires sudo)

```bash
# Build the container package
nix build github:jhhuh/claude-code-nix-sandbox#container

# Run Claude Code in an nspawn container
sudo ./result/bin/claude-sandbox-container /path/to/project

# Shell mode
sudo ./result/bin/claude-sandbox-container --shell /path/to/project
```

Requires `ANTHROPIC_API_KEY` in your environment, or an existing `~/.claude` login (auto-mounted).

## What's Sandboxed

| Resource | Access |
|---|---|
| Project directory | Read-write (bind-mounted) |
| `~/.claude` | Read-write (auth persistence) |
| `/nix/store` | Read-only |
| `/home` | Isolated (tmpfs) |
| `/tmp`, `/run` | Isolated (tmpfs) |
| Network | Shared by default |
| X11/Wayland | Forwarded from host |
| GPU (DRI) | Forwarded (software fallback on NVIDIA) |
| D-Bus | Session + system bus forwarded |

## Packages

| Package | Backend | Network | Requires |
|---|---|---|---|
| `default` | Bubblewrap | Full | User namespaces |
| `no-network` | Bubblewrap | Isolated | User namespaces |
| `container` | systemd-nspawn | Full | root (sudo) |
| `container-no-network` | systemd-nspawn | Isolated | root (sudo) |

## Requirements

- NixOS or Nix with flakes enabled
- Linux (bubblewrap requires user namespaces)
- X11 or Wayland display server
