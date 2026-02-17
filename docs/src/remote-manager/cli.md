# CLI (claude-remote)

`claude-remote` is a local CLI for managing sandboxes on a remote server. All commands run over SSH — no direct HTTP from your laptop.

## Installation

Available in the devShell or as a standalone package:

```bash
# Via devShell
nix develop github:jhhuh/claude-code-nix-sandbox
claude-remote help

# Standalone
nix build github:jhhuh/claude-code-nix-sandbox#cli
./result/bin/claude-remote help
```

## Configuration

Settings are resolved in order: **environment variable > config file > default**.

### Config file

Location: `${XDG_CONFIG_HOME:-~/.config}/claude-remote/config`

```
# ~/.config/claude-remote/config
host = myserver
port = 3000
ssh_opts = -i ~/.ssh/mykey
```

Lines starting with `#` are comments. Blank lines are ignored.

### Environment variables

| Variable | Config key | Default | Description |
|---|---|---|---|
| `CLAUDE_REMOTE_HOST` | `host` | — | Remote server hostname (required) |
| `CLAUDE_REMOTE_PORT` | `port` | `3000` | Manager port on the remote |
| `CLAUDE_REMOTE_SSH_OPTS` | `ssh_opts` | — | Extra SSH options (e.g. `-i ~/.ssh/key`) |

Environment variables always override config file values.

## Commands

### create

Create a new sandbox on the remote server.

```bash
claude-remote create <name> <backend> <project-dir> [--no-network] [--sync]
```

- `<backend>` — `bubblewrap`, `container`, or `vm`
- `--no-network` — disable network access
- `--sync` — rsync the local project directory to the remote before creating

### list

List all sandboxes (alias: `ls`).

```bash
claude-remote list
```

Output shows id (first 8 chars), name, backend, status, and project directory.

### attach

Attach to a sandbox's tmux session over SSH.

```bash
claude-remote attach <id-prefix>
```

The id-prefix can be any unique prefix of the sandbox UUID.

### stop

Stop a running sandbox.

```bash
claude-remote stop <id-prefix>
```

### delete

Delete a sandbox (alias: `rm`).

```bash
claude-remote delete <id-prefix>
```

### metrics

Show system metrics, and optionally sandbox-specific Claude session metrics.

```bash
claude-remote metrics              # system only
claude-remote metrics <id-prefix>  # system + sandbox Claude metrics
```

### sync

One-shot rsync from local to remote.

```bash
claude-remote sync <local-dir> [remote-dir]
```

If `remote-dir` is omitted, it defaults to the same path as `local-dir`. Excludes `.git/` and respects `.gitignore`.

### watch

Continuous bidirectional sync using fswatch + rsync.

```bash
claude-remote watch <local-dir> [remote-dir]
```

- Performs an initial local-to-remote sync
- Watches for local file changes and syncs to remote (debounced with 100ms window)
- Polls remote-to-local every 2 seconds in the background
- Excludes `.git/` and respects `.gitignore`
- Ctrl+C to stop

### ui

Forward the web dashboard via SSH tunnel.

```bash
claude-remote ui
# Then open http://localhost:3000
```
