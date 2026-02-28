use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    Bubblewrap,
    Container,
    Vm,
}

impl std::fmt::Display for Backend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Backend::Bubblewrap => write!(f, "bubblewrap"),
            Backend::Container => write!(f, "container"),
            Backend::Vm => write!(f, "vm"),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum SandboxStatus {
    Running,
    Stopped,
    Dead,
}

impl std::fmt::Display for SandboxStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SandboxStatus::Running => write!(f, "running"),
            SandboxStatus::Stopped => write!(f, "stopped"),
            SandboxStatus::Dead => write!(f, "dead"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Sandbox {
    pub id: String,
    pub name: String,
    pub backend: Backend,
    pub project_dir: String,
    pub status: SandboxStatus,
    pub display_num: Option<u32>,
    pub tmux_session: Option<String>,
    pub pid_xvfb: Option<u32>,
    pub qemu_qmp_socket: Option<String>,
    pub network: bool,
    pub created_at: DateTime<Utc>,
}

impl Sandbox {
    pub fn short_id(&self) -> &str {
        &self.id[..8.min(self.id.len())]
    }

    pub fn is_running(&self) -> bool {
        self.status == SandboxStatus::Running
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ManagerState {
    pub sandboxes: HashMap<String, Sandbox>,
    pub next_display: u32,
}

impl Default for ManagerState {
    fn default() -> Self {
        Self {
            sandboxes: HashMap::new(),
            next_display: 50,
        }
    }
}

impl ManagerState {
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(contents) => match serde_json::from_str(&contents) {
                Ok(state) => state,
                Err(e) => {
                    tracing::warn!("Failed to parse state file: {}", e);
                    Self::default()
                }
            },
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self, path: &Path) -> Result<(), std::io::Error> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(path, json)?;
        Ok(())
    }

    /// Check if tmux sessions are still alive, mark dead sandboxes
    pub fn reconcile_pids(&mut self) {
        for sandbox in self.sandboxes.values_mut() {
            if sandbox.status != SandboxStatus::Running {
                continue;
            }
            if let Some(ref session) = sandbox.tmux_session {
                let alive = std::process::Command::new("tmux")
                    .args(["has-session", "-t", session])
                    .output()
                    .map(|o| o.status.success())
                    .unwrap_or(false);
                if !alive {
                    tracing::info!(
                        "Sandbox {} tmux session gone, marking dead",
                        sandbox.short_id()
                    );
                    sandbox.status = SandboxStatus::Dead;
                }
            }
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateSandboxRequest {
    pub name: String,
    pub backend: Backend,
    pub project_dir: String,
    #[serde(default = "default_true")]
    pub network: bool,
}

fn default_true() -> bool {
    true
}

pub struct AppState {
    pub manager: RwLock<ManagerState>,
    pub state_path: PathBuf,
    pub log_dir: PathBuf,
    pub screenshots: RwLock<HashMap<String, Vec<u8>>>,
}

pub type SharedState = Arc<AppState>;
