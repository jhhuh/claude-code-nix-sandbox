# WebSocket Log Viewer — Design

## Goal

Stream sandbox terminal output to the web dashboard in real-time via WebSocket, so users can see what's happening inside a sandbox without SSH + tmux attach.

## Architecture

Three components: log capture via `tmux pipe-pane`, an Axum WebSocket endpoint that tails the log file, and a minimal vendored JS client that renders output in a `<pre>` element.

## Scope

- **Read-only** — output streaming only, no input/keystrokes (bidirectional is a future feature)
- **Part 1 of 4** in the manager features roadmap: log viewing → monitoring/alerting → lifecycle controls → multi-user/auth

## Components

### 1. Log capture (tmux pipe-pane)

When a sandbox starts, immediately after `tmux new-session`, run:

```bash
tmux pipe-pane -o -t <session> 'cat >> <log_dir>/<sandbox_id>.log'
```

- `-o` captures output only (matches read-only scope)
- Log files in `<state_dir>/logs/` (alongside `state.json`)
- pipe-pane stops automatically when tmux session dies
- Log files persist after sandbox stops (reviewable)
- On sandbox delete, log file is cleaned up

### 2. WebSocket server (new `logs.rs` module)

**Endpoint:** `GET /ws/sandboxes/:id/logs` — WebSocket upgrade

**Behavior:**
1. Validate sandbox exists
2. Open log file, read last 1000 lines as initial payload
3. Send initial lines as a single text frame
4. Poll file every 100ms for new data via `tokio::fs` + `tokio::time::interval`
5. Send new lines as text frames
6. If log file doesn't exist yet, wait for it to appear
7. Close on client disconnect

**Dependencies:** Axum's built-in WebSocket support (`axum::extract::ws`). No new crates — file polling uses `tokio::fs` + `tokio::time::interval`.

### 3. Browser client (`static/logs.js`)

Vendored JS file, no build step. Follows project convention (like vendored htmx).

**Behavior:**
- Connects to `ws://<host>/ws/sandboxes/<id>/logs`
- Appends received text to `<pre id="log-output">`
- Auto-scrolls to bottom unless user has scrolled up
- Reconnects with exponential backoff (1s → 2s → 4s → ... capped at 30s)
- Shows connection status indicator (connected/reconnecting/disconnected)

**No xterm.js** — styled `<pre>` is sufficient for read-only. ANSI escape codes show raw in v1. Can add ANSI-to-HTML converter later.

### 4. Template changes

`templates/sandbox.html` detail page:
- New "Logs" section below screenshot panel
- `<pre id="log-output">` with monospace font, dark background, max-height, overflow-y scroll
- Script tag loads `logs.js`, passes sandbox ID

## Files to create/modify

| Action | File | Purpose |
|--------|------|---------|
| Create | `manager/src/logs.rs` | WebSocket handler + file tailing |
| Create | `manager/static/logs.js` | Browser WebSocket client |
| Modify | `manager/src/main.rs` | Add `mod logs`, WebSocket route |
| Modify | `manager/src/sandbox.rs` | Start `tmux pipe-pane` after session create |
| Modify | `manager/src/session.rs` | Add `pipe_pane()` and log path helper |
| Modify | `manager/src/state.rs` | Add log file path to Sandbox struct, cleanup on delete |
| Modify | `manager/templates/sandbox.html` | Add logs section |
| Create | `manager/templates/fragments/log_viewer.html` | Log viewer fragment |

## Future extensions (not in scope)

- Bidirectional input (web terminal)
- xterm.js for proper ANSI rendering
- Log search/filter
- Log export/download
- Log retention policy
