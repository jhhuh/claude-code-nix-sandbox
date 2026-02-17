use crate::display;
use crate::session;
use crate::state::{AppState, Backend, CreateSandboxRequest, Sandbox, SandboxStatus};
use chrono::Utc;
use uuid::Uuid;

pub async fn create_sandbox(
    state: &AppState,
    req: CreateSandboxRequest,
) -> Result<Sandbox, String> {
    let id = Uuid::new_v4().to_string();
    let short_id = id[..8].to_string();
    let tmux_session = format!("sandbox-{}", short_id);

    // Allocate display number (VM has its own Xorg, skip Xvfb)
    let display_num = match req.backend {
        Backend::Vm => None,
        _ => {
            let mut manager = state.manager.write().await;
            let num = display::allocate_display(manager.next_display);
            manager.next_display = num + 1;
            Some(num)
        }
    };

    // Start Xvfb outside of lock
    let pid_xvfb = match display_num {
        Some(num) => {
            let pid =
                display::start_xvfb(num).map_err(|e| format!("Failed to start Xvfb: {}", e))?;
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            Some(pid)
        }
        None => None,
    };

    // Build the backend command
    let backend_cmd = match req.backend {
        Backend::Bubblewrap => format!("claude-sandbox {}", req.project_dir),
        Backend::Container => format!("sudo claude-sandbox-container {}", req.project_dir),
        Backend::Vm => format!("claude-sandbox-vm {}", req.project_dir),
    };

    // Create tmux session
    session::create_session(&tmux_session, display_num, &backend_cmd, &req.project_dir)
        .map_err(|e| format!("Failed to create tmux session: {}", e))?;

    let qemu_qmp_socket = if req.backend == Backend::Vm {
        Some(format!("/run/claude-manager/qmp-{}.sock", short_id))
    } else {
        None
    };

    let sandbox = Sandbox {
        id: id.clone(),
        name: req.name,
        backend: req.backend,
        project_dir: req.project_dir,
        status: SandboxStatus::Running,
        display_num,
        tmux_session: Some(tmux_session),
        pid_xvfb,
        qemu_qmp_socket,
        network: req.network,
        created_at: Utc::now(),
    };

    let mut manager = state.manager.write().await;
    manager.sandboxes.insert(id, sandbox.clone());
    let _ = manager.save(&state.state_path);

    Ok(sandbox)
}

pub async fn stop_sandbox(state: &AppState, id: &str) -> Result<(), String> {
    let mut manager = state.manager.write().await;
    let sandbox = manager
        .sandboxes
        .get_mut(id)
        .ok_or_else(|| "Sandbox not found".to_string())?;

    if let Some(ref session) = sandbox.tmux_session {
        session::kill_session(session);
    }
    if let Some(pid) = sandbox.pid_xvfb {
        display::stop_xvfb(pid);
    }

    sandbox.status = SandboxStatus::Stopped;
    let _ = manager.save(&state.state_path);
    drop(manager);

    state.screenshots.write().await.remove(id);
    Ok(())
}

pub async fn delete_sandbox(state: &AppState, id: &str) -> Result<(), String> {
    // Stop first if running
    {
        let manager = state.manager.read().await;
        if let Some(sandbox) = manager.sandboxes.get(id) {
            if sandbox.status == SandboxStatus::Running {
                drop(manager);
                stop_sandbox(state, id).await?;
            }
        }
    }

    let mut manager = state.manager.write().await;
    manager.sandboxes.remove(id);
    let _ = manager.save(&state.state_path);
    Ok(())
}
