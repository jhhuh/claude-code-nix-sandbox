use std::process::Command;

/// Create a new tmux session running `command` with DISPLAY set
pub fn create_session(
    session_name: &str,
    display_num: Option<u32>,
    command: &str,
    working_dir: &str,
) -> std::io::Result<()> {
    let mut cmd = Command::new("tmux");
    cmd.args(["new-session", "-d", "-s", session_name, "-c", working_dir]);

    if let Some(num) = display_num {
        cmd.env("DISPLAY", format!(":{}", num));
    }

    // The remaining arg is the shell command to run inside tmux
    cmd.arg(command);

    let output = cmd.output()?;
    if !output.status.success() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            String::from_utf8_lossy(&output.stderr).to_string(),
        ));
    }
    Ok(())
}

/// Check if a tmux session exists (used by monitor loop)
#[allow(dead_code)]
pub fn has_session(session_name: &str) -> bool {
    Command::new("tmux")
        .args(["has-session", "-t", session_name])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Kill a tmux session
pub fn kill_session(session_name: &str) {
    let _ = Command::new("tmux")
        .args(["kill-session", "-t", session_name])
        .output();
}
