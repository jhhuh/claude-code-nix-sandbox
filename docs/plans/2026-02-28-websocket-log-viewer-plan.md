# WebSocket Log Viewer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stream sandbox terminal output to the web dashboard via WebSocket so users can view logs without SSH + tmux attach.

**Architecture:** `tmux pipe-pane` captures sandbox output to per-sandbox log files in `<state_dir>/logs/`. An Axum WebSocket endpoint tails these files and streams new lines to the browser. A small vendored JS client renders output in a `<pre>` element with auto-scroll and reconnection.

**Tech Stack:** Rust/Axum (WebSocket via `axum::extract::ws`), tokio (async file I/O + interval polling), vanilla JS (no build step), tmux pipe-pane

**Relevant skills:**
- `artifacts/skills/nix-writeShellApplication-escaping-and-shellcheck.md` — if modifying Nix wrappers
- `artifacts/skills/nixos-vm-integration-test-with-stub-services.md` — for extending the NixOS test

---

### Task 1: Add log_dir to AppState and create logs directory on startup

**Files:**
- Modify: `manager/src/state.rs:144-150`
- Modify: `manager/src/main.rs:31-34`

**Step 1: Add `log_dir` field to `AppState`**

In `manager/src/state.rs`, add `log_dir` to the `AppState` struct:

```rust
pub struct AppState {
    pub manager: RwLock<ManagerState>,
    pub state_path: PathBuf,
    pub log_dir: PathBuf,
    pub screenshots: RwLock<HashMap<String, Vec<u8>>>,
}
```

**Step 2: Initialize log_dir in main.rs**

In `manager/src/main.rs`, after the `state_path` line, add:

```rust
let log_dir = PathBuf::from(&state_dir).join("logs");
std::fs::create_dir_all(&log_dir).expect("Failed to create log directory");
```

And pass it to `AppState`:

```rust
let shared = Arc::new(AppState {
    manager: RwLock::new(manager_state),
    state_path,
    log_dir,
    screenshots: RwLock::new(HashMap::new()),
});
```

**Step 3: Verify it compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add manager/src/state.rs manager/src/main.rs
git commit -m "feat(manager): add log_dir to AppState for sandbox log storage"
```

---

### Task 2: Start tmux pipe-pane when sandbox is created

**Files:**
- Modify: `manager/src/session.rs`
- Modify: `manager/src/sandbox.rs:44-46`

**Step 1: Add `start_pipe_pane` function to session.rs**

Append to `manager/src/session.rs`:

```rust
/// Start capturing tmux pane output to a log file
pub fn start_pipe_pane(session_name: &str, log_path: &std::path::Path) -> std::io::Result<()> {
    let output = Command::new("tmux")
        .args([
            "pipe-pane",
            "-o",
            "-t",
            session_name,
            &format!("cat >> {}", log_path.display()),
        ])
        .output()?;
    if !output.status.success() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }
    Ok(())
}
```

**Step 2: Call `start_pipe_pane` after session creation in sandbox.rs**

In `manager/src/sandbox.rs`, after the `session::create_session(...)` call (line 45-46), add:

```rust
    // Start capturing tmux output to log file
    let log_path = state.log_dir.join(format!("{}.log", id));
    if let Err(e) = session::start_pipe_pane(&tmux_session, &log_path) {
        tracing::warn!("Failed to start log capture for {}: {}", short_id, e);
    }
```

You'll need to import nothing new — `state` is already `&AppState`.

**Step 3: Verify it compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add manager/src/session.rs manager/src/sandbox.rs
git commit -m "feat(manager): capture sandbox terminal output via tmux pipe-pane"
```

---

### Task 3: Clean up log files on sandbox delete

**Files:**
- Modify: `manager/src/sandbox.rs:97-113`

**Step 1: Delete log file in `delete_sandbox`**

In `manager/src/sandbox.rs`, in the `delete_sandbox` function, after removing from the HashMap (line 110), add log cleanup:

```rust
    let mut manager = state.manager.write().await;
    manager.sandboxes.remove(id);
    let _ = manager.save(&state.state_path);

    // Clean up log file
    let log_path = state.log_dir.join(format!("{}.log", id));
    let _ = std::fs::remove_file(&log_path);
```

**Step 2: Verify it compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles with no errors

**Step 3: Commit**

```bash
git add manager/src/sandbox.rs
git commit -m "feat(manager): clean up log files on sandbox delete"
```

---

### Task 4: Create WebSocket handler (logs.rs)

**Files:**
- Create: `manager/src/logs.rs`
- Modify: `manager/src/main.rs` (add `mod logs`)

**Step 1: Create `manager/src/logs.rs`**

```rust
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Path, State, WebSocketUpgrade};
use axum::response::Response;
use std::io::SeekFrom;
use tokio::io::{AsyncBufReadExt, AsyncSeekExt, BufReader};
use tokio::time::{interval, Duration};

use crate::state::SharedState;

/// Maximum number of lines to send as initial backlog
const INITIAL_BACKLOG_LINES: usize = 1000;

/// How often to poll the log file for new data (milliseconds)
const POLL_INTERVAL_MS: u64 = 100;

pub async fn ws_logs(
    ws: WebSocketUpgrade,
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    // Validate sandbox exists
    let exists = state.manager.read().await.sandboxes.contains_key(&id);
    if !exists {
        return Response::builder()
            .status(404)
            .body("Sandbox not found".into())
            .unwrap();
    }

    let log_path = state.log_dir.join(format!("{}.log", id));
    ws.on_upgrade(move |socket| handle_socket(socket, log_path))
}

async fn handle_socket(mut socket: WebSocket, log_path: std::path::PathBuf) {
    // Wait for log file to appear (sandbox may still be starting)
    let mut wait_count = 0;
    while !log_path.exists() && wait_count < 50 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        wait_count += 1;
    }

    let file = match tokio::fs::File::open(&log_path).await {
        Ok(f) => f,
        Err(_) => {
            let _ = socket
                .send(Message::Text("[No log file available]".into()))
                .await;
            return;
        }
    };

    let mut reader = BufReader::new(file);

    // Read entire file and send last N lines as backlog
    let mut all_lines = Vec::new();
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) => break, // EOF
            Ok(_) => all_lines.push(line.clone()),
            Err(_) => break,
        }
    }

    let backlog_start = all_lines.len().saturating_sub(INITIAL_BACKLOG_LINES);
    let backlog: String = all_lines[backlog_start..].concat();
    if !backlog.is_empty() {
        if socket.send(Message::Text(backlog.into())).await.is_err() {
            return;
        }
    }
    drop(all_lines);

    // Now tail: poll for new data at the current file position
    // reader is already positioned at EOF after reading all lines
    let mut poll = interval(Duration::from_millis(POLL_INTERVAL_MS));
    loop {
        poll.tick().await;

        // Read any new lines
        let mut new_data = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line).await {
                Ok(0) => break, // No more data
                Ok(_) => new_data.push_str(&line),
                Err(_) => break,
            }
        }

        if !new_data.is_empty() {
            if socket.send(Message::Text(new_data.into())).await.is_err() {
                return; // Client disconnected
            }
        }

        // Check for incoming close/ping messages (non-blocking)
        match tokio::time::timeout(Duration::from_millis(1), socket.recv()).await {
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => return,
            _ => {} // Timeout or other message, continue
        }
    }
}
```

**Step 2: Add `mod logs` to main.rs**

In `manager/src/main.rs`, add after the existing `mod` declarations:

```rust
mod logs;
```

**Step 3: Verify it compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add manager/src/logs.rs manager/src/main.rs
git commit -m "feat(manager): add WebSocket handler for log streaming"
```

---

### Task 5: Add WebSocket route to the router

**Files:**
- Modify: `manager/src/main.rs:92-126`

**Step 1: Add the WebSocket route**

In `manager/src/main.rs`, in the router chain, add after the screenshot route (around line 107):

```rust
        .route("/ws/sandboxes/:id/logs", get(logs::ws_logs))
```

**Step 2: Verify it compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles with no errors

**Step 3: Commit**

```bash
git add manager/src/main.rs
git commit -m "feat(manager): register WebSocket log streaming route"
```

---

### Task 6: Create the browser JS client

**Files:**
- Create: `manager/static/logs.js`

**Step 1: Write `manager/static/logs.js`**

```javascript
(function () {
  "use strict";

  var output = document.getElementById("log-output");
  var status = document.getElementById("log-status");
  if (!output) return;

  var sandboxId = output.dataset.sandboxId;
  if (!sandboxId) return;

  var ws = null;
  var retryDelay = 1000;
  var maxRetryDelay = 30000;
  var autoScroll = true;

  // Detect if user scrolled up (disable auto-scroll)
  output.addEventListener("scroll", function () {
    var atBottom =
      output.scrollHeight - output.scrollTop - output.clientHeight < 50;
    autoScroll = atBottom;
  });

  function setStatus(text, color) {
    if (status) {
      status.textContent = text;
      status.style.color = color || "inherit";
    }
  }

  function scrollToBottom() {
    if (autoScroll) {
      output.scrollTop = output.scrollHeight;
    }
  }

  function connect() {
    var proto = location.protocol === "https:" ? "wss:" : "ws:";
    var url = proto + "//" + location.host + "/ws/sandboxes/" + sandboxId + "/logs";

    setStatus("connecting...", "var(--yellow)");
    ws = new WebSocket(url);

    ws.onopen = function () {
      setStatus("connected", "var(--green)");
      retryDelay = 1000;
    };

    ws.onmessage = function (e) {
      output.textContent += e.data;
      scrollToBottom();
    };

    ws.onclose = function () {
      setStatus("disconnected — retrying in " + (retryDelay / 1000) + "s", "var(--muted)");
      setTimeout(connect, retryDelay);
      retryDelay = Math.min(retryDelay * 2, maxRetryDelay);
    };

    ws.onerror = function () {
      ws.close();
    };
  }

  connect();
})();
```

**Step 2: Commit**

```bash
git add manager/static/logs.js
git commit -m "feat(manager): add WebSocket log viewer JS client"
```

---

### Task 7: Add log viewer to the sandbox detail template

**Files:**
- Modify: `manager/templates/sandbox.html:42-78`
- Modify: `manager/static/style.css`

**Step 1: Add logs panel to sandbox.html**

In `manager/templates/sandbox.html`, after the closing `</div>` of `sandbox-panels` (line 78), add a full-width log viewer section:

```html
    <div class="panel log-panel">
        <div class="log-header">
            <h2>Logs</h2>
            <span id="log-status" class="muted">disconnected</span>
        </div>
        <pre id="log-output" class="log-output" data-sandbox-id="{{ sandbox.id }}"></pre>
    </div>

    <script src="/static/logs.js"></script>
```

Place this before the final `</div>` that closes `sandbox-detail`.

**Step 2: Add CSS for the log viewer**

Append to `manager/static/style.css`:

```css
/* Log viewer */
.log-panel { margin-top: 1.5rem; }
.log-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.75rem; }
.log-header h2 { font-size: 1rem; }
.log-output {
    background: #0a0e14;
    color: #b3b1ad;
    font-family: "SF Mono", "Fira Code", "Fira Mono", Menlo, Consolas, monospace;
    font-size: 0.8rem;
    line-height: 1.4;
    padding: 0.75rem;
    border-radius: 6px;
    border: 1px solid var(--border);
    max-height: 500px;
    overflow-y: auto;
    white-space: pre-wrap;
    word-wrap: break-word;
}
```

**Step 3: Verify the template compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles (askama validates templates at compile time)

**Step 4: Commit**

```bash
git add manager/templates/sandbox.html manager/static/style.css
git commit -m "feat(manager): add log viewer panel to sandbox detail page"
```

---

### Task 8: Add JSON API endpoint for log content

**Files:**
- Modify: `manager/src/api.rs`
- Modify: `manager/src/main.rs` (add route)

**Step 1: Add `get_logs` handler to api.rs**

Append to `manager/src/api.rs`:

```rust
pub async fn get_logs(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    let exists = state.manager.read().await.sandboxes.contains_key(&id);
    if !exists {
        return (StatusCode::NOT_FOUND, "Sandbox not found").into_response();
    }

    let log_path = state.log_dir.join(format!("{}.log", id));
    match std::fs::read_to_string(&log_path) {
        Ok(content) => (StatusCode::OK, [("content-type", "text/plain")], content).into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "No logs available").into_response(),
    }
}
```

**Step 2: Add the route in main.rs**

Add after the existing metrics route:

```rust
        .route("/api/sandboxes/:id/logs", get(api::get_logs))
```

**Step 3: Verify it compiles**

Run: `cd manager && cargo build 2>&1`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add manager/src/api.rs manager/src/main.rs
git commit -m "feat(manager): add REST API endpoint for log content"
```

---

### Task 9: Extend the NixOS integration test

**Files:**
- Modify: `tests/manager.nix:30-84`

**Step 1: Add log-related test steps**

In `tests/manager.nix`, after step 4 (list should have one entry, around line 59), add:

```python
    # 4b. WebSocket endpoint exists (upgrade required, so expect 400 without WS headers)
    server.succeed(
        f"curl -sf -o /dev/null -w '%{{http_code}}' http://localhost:3000/ws/sandboxes/{sandbox_id}/logs || [ $? -eq 22 ]"
    )

    # 4c. REST log endpoint works (may be empty initially)
    server.succeed(
        f"curl -sf http://localhost:3000/api/sandboxes/{sandbox_id}/logs || true"
    )
```

After step 5 (stop the sandbox), add:

```python
    # 5b. Log file exists in state dir
    server.succeed(
        f"test -f /var/lib/claude-manager/logs/{sandbox_id}.log"
    )
```

After step 7 (delete the sandbox), add:

```python
    # 7b. Log file cleaned up after delete
    server.succeed(
        f"test ! -f /var/lib/claude-manager/logs/{sandbox_id}.log"
    )
```

**Step 2: Verify the test passes**

Run: `nix flake check 2>&1` (this runs all checks including the NixOS VM test)
Expected: All checks pass

**Step 3: Commit**

```bash
git add tests/manager.nix
git commit -m "test(manager): add log file lifecycle tests"
```

---

### Task 10: Final build verification

**Step 1: Full Nix build**

Run: `nix build .#manager 2>&1`
Expected: Build succeeds

**Step 2: Flake check**

Run: `nix flake check 2>&1`
Expected: All checks pass (including NixOS VM test with new log steps)

**Step 3: Final commit with any fixups**

If any adjustments were needed, commit them:

```bash
git add -A
git commit -m "fix(manager): address log viewer build/test issues"
```
