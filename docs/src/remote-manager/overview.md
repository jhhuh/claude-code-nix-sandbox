# Remote Manager

Run sandboxes on a remote server and manage them from your laptop via a web dashboard or CLI. The manager is a Rust/Axum daemon that orchestrates sandbox lifecycles, captures live screenshots, and collects metrics.

## Architecture

```
laptop                              remote server
  │                                   │
  │  claude-remote create ...         │ manager daemon (127.0.0.1:3000)
  │ ─────────────────────────────────>│   ├── starts Xvfb display
  │                                   │   ├── starts tmux session
  │  claude-remote attach <id>        │   ├── runs sandbox backend
  │ ─────────────────────────────────>│   ├── captures screenshots
  │                                   │   └── collects metrics
  │  claude-remote ui                 │
  │  open http://localhost:3000       │ web dashboard (htmx, live refresh)
  │ ─────────────────────────────────>│
```

All communication happens over SSH — the CLI runs `ssh $HOST curl ...` to talk to the manager's localhost-only HTTP API.

## Running the manager

```bash
# Build
nix build github:jhhuh/claude-code-nix-sandbox#manager

# Run
MANAGER_LISTEN=127.0.0.1:3000 ./result/bin/claude-sandbox-manager
```

Or deploy as a NixOS systemd service — see [Manager Module](../nixos-modules/manager.md).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `MANAGER_LISTEN` | `127.0.0.1:3000` | Listen address and port |
| `MANAGER_STATE_DIR` | `.` | Directory for `state.json` persistence |
| `MANAGER_STATIC_DIR` | (set by Nix wrapper) | Path to static web assets |

## Components

The manager daemon runs three concurrent tasks:

1. **HTTP server** — Axum router serving pages, JSON API, htmx fragments, and static files
2. **Liveness monitor** — checks tmux sessions every 5 seconds, marks dead sandboxes
3. **Screenshot loop** — captures Xvfb displays (ImageMagick `import`) or QEMU QMP screendumps every 2 seconds

## State persistence

Sandbox state is persisted as JSON in `$MANAGER_STATE_DIR/state.json`. On startup, the manager loads existing state and reconciles PIDs — any sandbox whose tmux session has disappeared is marked as dead.

## Runtime dependencies

The Nix package wraps the manager binary with these tools on PATH:

- **ImageMagick** — Xvfb screenshot capture (`import`)
- **socat** — QEMU QMP communication
- **tmux** — sandbox session management
- **Xvfb** (xorgserver) — virtual framebuffer for bubblewrap/container backends
- **Sandbox backends** — configured via `sandboxPackages` parameter
