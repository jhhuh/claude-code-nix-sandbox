use askama::Template;
use axum::extract::{Path, State};
use axum::response::IntoResponse;

use crate::metrics::{self, ClaudeMetrics, SystemMetrics};
use crate::state::{Sandbox, SharedState};

// ---------------------------------------------------------------------------
// Fragment templates (htmx partials — no {% extends %})
// ---------------------------------------------------------------------------

#[derive(Template)]
#[template(path = "fragments/sandbox_list.html")]
pub struct SandboxListFragment {
    pub sandboxes: Vec<Sandbox>,
}

#[derive(Template)]
#[template(path = "fragments/system_metrics.html")]
pub struct SystemMetricsFragment {
    pub metrics: SystemMetrics,
}

#[derive(Template)]
#[template(path = "fragments/claude_metrics.html")]
pub struct ClaudeMetricsFragment {
    pub metrics: ClaudeMetrics,
}

#[derive(Template)]
#[template(path = "fragments/screenshot_frame.html")]
pub struct ScreenshotFrameFragment {
    pub sandbox_id: String,
    pub has_screenshot: bool,
}

// ---------------------------------------------------------------------------
// Fragment handlers
// ---------------------------------------------------------------------------

pub async fn sandbox_list(State(state): State<SharedState>) -> impl IntoResponse {
    let manager = state.manager.read().await;
    let mut sandboxes: Vec<Sandbox> = manager.sandboxes.values().cloned().collect();
    sandboxes.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    SandboxListFragment { sandboxes }
}

pub async fn system_metrics() -> impl IntoResponse {
    let metrics = metrics::collect_system_metrics();
    SystemMetricsFragment { metrics }
}

pub async fn claude_metrics(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let manager = state.manager.read().await;
    let metrics = manager
        .sandboxes
        .get(&id)
        .and_then(|sb| metrics::parse_claude_metrics(&sb.project_dir))
        .unwrap_or_default();
    ClaudeMetricsFragment { metrics }
}

pub async fn screenshot_frame(
    State(state): State<SharedState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let has_screenshot = state.screenshots.read().await.contains_key(&id);
    ScreenshotFrameFragment {
        sandbox_id: id,
        has_screenshot,
    }
}
