# claude-code-nix-sandbox

Launch sandboxed [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code) sessions with Chromium using Nix.

Claude Code runs inside a [bubblewrap](https://github.com/containers/bubblewrap) sandbox with filesystem isolation, display forwarding, and a Chromium browser — all from nixpkgs.

## Quick Start

```bash
# Run Claude Code in a sandbox (project dir is the only writable mount)
nix run github:jhhuh/claude-code-nix-sandbox -- /path/to/project

# Drop into a shell inside the sandbox for debugging
nix run github:jhhuh/claude-code-nix-sandbox -- --shell /path/to/project

# Build locally
nix build github:jhhuh/claude-code-nix-sandbox
./result/bin/claude-sandbox /path/to/project
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

| Package | Description |
|---|---|
| `default` | Bubblewrap sandbox with full network |
| `no-network` | Same but with `--unshare-net` |

## Requirements

- NixOS or Nix with flakes enabled
- Linux (bubblewrap requires user namespaces)
- X11 or Wayland display server
