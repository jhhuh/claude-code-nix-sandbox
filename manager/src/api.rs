use askama::Template;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Redirect, Response};

use crate::metrics::{self, ClaudeMetrics, SystemMetrics};
use crate::sandbox;
use crate::state::{CreateSandboxRequest, Sandbox, SharedState};

// ---------------------------------------------------------------------------
// Page templates
// ---------------------------------------------------------------------------

#[derive(Template)]
#[template(path = "index.html")]
pub struct IndexTemplate {
    pub sandboxes: Vec<Sandbox>,
}

#[derive(Template)]
#[template(path = "new.html")]
pub struct NewTemplate;

#[derive(Template)]
#[template(path = "sandbox.html")]
pub struct SandboxDetailTemplate {
    pub sandbox: Sandbox,
    pub metrics: Option<ClaudeMetrics>,
}

// ---------------------------------------------------------------------------
// Page handlers
// ---------------------------------------------------------------------------

pub async fn index(State(state): State<SharedState>) -> impl IntoResponse {
    let manager = state.manager.read().await;
    let mut sandboxes: Vec<Sandbox> = manager.sandboxes.values().cloned().collect();
    sandboxes.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    IndexTemplate { sandboxes }
}

pub async fn new_sandbox_form() -> impl IntoResponse {
    NewTemplate
}

pub async fn sandbox_detail(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    let manager = state.manager.read().await;
    match manager.sandboxes.get(&id) {
        Some(sb) => {
            let claude_metrics = metrics::parse_claude_metrics(&sb.project_dir);
            SandboxDetailTemplate {
                sandbox: sb.clone(),
                metrics: claude_metrics,
            }
            .into_response()
        }
        None => (StatusCode::NOT_FOUND, "Sandbox not found").into_response(),
    }
}

// ---------------------------------------------------------------------------
// JSON API handlers
// ---------------------------------------------------------------------------

pub async fn list_sandboxes(State(state): State<SharedState>) -> impl IntoResponse {
    let manager = state.manager.read().await;
    let mut sandboxes: Vec<Sandbox> = manager.sandboxes.values().cloned().collect();
    sandboxes.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Json(sandboxes)
}

pub async fn get_sandbox(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    let manager = state.manager.read().await;
    match manager.sandboxes.get(&id) {
        Some(sb) => Json(sb.clone()).into_response(),
        None => (StatusCode::NOT_FOUND, "Sandbox not found").into_response(),
    }
}

pub async fn create_sandbox_api(
    State(state): State<SharedState>,
    Json(req): Json<CreateSandboxRequest>,
) -> Response {
    match sandbox::create_sandbox(&state, req).await {
        Ok(sb) => (StatusCode::CREATED, Json(sb)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

/// Handle the HTML form POST (application/x-www-form-urlencoded)
pub async fn create_sandbox_form(
    State(state): State<SharedState>,
    axum::extract::Form(req): axum::extract::Form<CreateSandboxRequest>,
) -> Response {
    match sandbox::create_sandbox(&state, req).await {
        Ok(sb) => Redirect::to(&format!("/sandboxes/{}", sb.id)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

pub async fn stop_sandbox_api(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    match sandbox::stop_sandbox(&state, &id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

pub async fn delete_sandbox_api(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    match sandbox::delete_sandbox(&state, &id).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

pub async fn get_screenshot(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    let screenshots = state.screenshots.read().await;
    match screenshots.get(&id) {
        Some(png) => (
            StatusCode::OK,
            [("content-type", "image/png")],
            png.clone(),
        )
            .into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

pub async fn get_sandbox_metrics(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> Response {
    let manager = state.manager.read().await;
    match manager.sandboxes.get(&id) {
        Some(sb) => {
            let m = metrics::parse_claude_metrics(&sb.project_dir)
                .unwrap_or_default();
            Json(m).into_response()
        }
        None => (StatusCode::NOT_FOUND, "Sandbox not found").into_response(),
    }
}

pub async fn get_system_metrics() -> impl IntoResponse {
    Json(metrics::collect_system_metrics())
}

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

// ---------------------------------------------------------------------------
// System metrics type re-export for templates
// ---------------------------------------------------------------------------

impl SystemMetrics {
    pub fn memory_used_gb(&self) -> f64 {
        self.memory_used as f64 / 1_073_741_824.0
    }
    pub fn memory_total_gb(&self) -> f64 {
        self.memory_total as f64 / 1_073_741_824.0
    }
    pub fn disk_used_gb(&self) -> f64 {
        self.disk_used as f64 / 1_073_741_824.0
    }
    pub fn disk_total_gb(&self) -> f64 {
        self.disk_total as f64 / 1_073_741_824.0
    }
}
