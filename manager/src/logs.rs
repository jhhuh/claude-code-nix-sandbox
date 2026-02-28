use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Path, State, WebSocketUpgrade};
use axum::response::Response;
use tokio::io::AsyncBufReadExt;

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
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
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

    let mut reader = tokio::io::BufReader::new(file);

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
    let mut poll = tokio::time::interval(tokio::time::Duration::from_millis(POLL_INTERVAL_MS));
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
        match tokio::time::timeout(
            tokio::time::Duration::from_millis(1),
            socket.recv(),
        )
        .await
        {
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => return,
            _ => {} // Timeout or other message, continue
        }
    }
}
