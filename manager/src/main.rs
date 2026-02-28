use axum::routing::{get, post};
use axum::Router;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tower_http::services::ServeDir;

mod api;
mod display;
mod fragments;
mod metrics;
mod sandbox;
mod screenshot;
mod session;
mod state;

use state::{AppState, ManagerState, SandboxStatus};

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let listen_addr =
        std::env::var("MANAGER_LISTEN").unwrap_or_else(|_| "127.0.0.1:3000".into());
    let state_dir =
        std::env::var("MANAGER_STATE_DIR").unwrap_or_else(|_| ".".into());
    let static_dir =
        std::env::var("MANAGER_STATIC_DIR").unwrap_or_else(|_| "static".into());

    let state_path = PathBuf::from(&state_dir).join("state.json");
    let log_dir = PathBuf::from(&state_dir).join("logs");
    std::fs::create_dir_all(&log_dir).expect("Failed to create log directory");
    let mut manager_state = ManagerState::load(&state_path);
    manager_state.reconcile_pids();
    let _ = manager_state.save(&state_path);

    let shared = Arc::new(AppState {
        manager: RwLock::new(manager_state),
        state_path,
        log_dir,
        screenshots: RwLock::new(HashMap::new()),
    });

    // Background: monitor sandbox liveness every 5s
    {
        let s = shared.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                let mut mgr = s.manager.write().await;
                mgr.reconcile_pids();
                let _ = mgr.save(&s.state_path);
            }
        });
    }

    // Background: capture screenshots every 2s for running sandboxes
    {
        let s = shared.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                let ids_and_info: Vec<(String, Option<u32>, Option<String>)> = {
                    let mgr = s.manager.read().await;
                    mgr.sandboxes
                        .values()
                        .filter(|sb| sb.status == SandboxStatus::Running)
                        .map(|sb| {
                            (
                                sb.id.clone(),
                                sb.display_num,
                                sb.qemu_qmp_socket.clone(),
                            )
                        })
                        .collect()
                };

                for (id, display_num, qmp_socket) in ids_and_info {
                    let png = if let Some(num) = display_num {
                        screenshot::capture_xvfb(num)
                    } else if let Some(ref sock) = qmp_socket {
                        screenshot::capture_qmp(sock)
                    } else {
                        None
                    };
                    if let Some(data) = png {
                        s.screenshots.write().await.insert(id, data);
                    }
                }
            }
        });
    }

    let app = Router::new()
        // Pages
        .route("/", get(api::index))
        .route("/new", get(api::new_sandbox_form).post(api::create_sandbox_form))
        .route("/sandboxes/:id", get(api::sandbox_detail))
        // JSON API
        .route(
            "/api/sandboxes",
            get(api::list_sandboxes).post(api::create_sandbox_api),
        )
        .route("/api/sandboxes/:id", get(api::get_sandbox).delete(api::delete_sandbox_api))
        .route("/api/sandboxes/:id/stop", post(api::stop_sandbox_api))
        .route(
            "/api/sandboxes/:id/screenshot",
            get(api::get_screenshot),
        )
        .route(
            "/api/sandboxes/:id/metrics",
            get(api::get_sandbox_metrics),
        )
        .route("/api/metrics/system", get(api::get_system_metrics))
        // htmx fragments
        .route("/fragments/sandbox-list", get(fragments::sandbox_list))
        .route("/fragments/system-metrics", get(fragments::system_metrics))
        .route(
            "/fragments/sandboxes/:id/claude-metrics",
            get(fragments::claude_metrics),
        )
        .route(
            "/fragments/sandboxes/:id/screenshot",
            get(fragments::screenshot_frame),
        )
        // Static files
        .nest_service("/static", ServeDir::new(&static_dir))
        .with_state(shared);

    tracing::info!("Listening on {}", listen_addr);
    let listener = tokio::net::TcpListener::bind(&listen_addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
