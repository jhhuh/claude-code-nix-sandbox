use std::process::Command;

/// Check if an X display number is already in use
pub fn is_display_in_use(display_num: u32) -> bool {
    let lock_file = format!("/tmp/.X{}-lock", display_num);
    std::path::Path::new(&lock_file).exists()
}

/// Find the next free display number starting from `start`
pub fn allocate_display(start: u32) -> u32 {
    let mut num = start;
    while is_display_in_use(num) {
        num += 1;
    }
    num
}

/// Start Xvfb on the given display number, return its PID
pub fn start_xvfb(display_num: u32) -> std::io::Result<u32> {
    let display = format!(":{}", display_num);
    let child = Command::new("Xvfb")
        .args([&display, "-screen", "0", "1920x1080x24", "-ac"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    // Child::drop does NOT kill the process on Unix — it continues running
    Ok(child.id())
}

/// Kill an Xvfb process by PID
pub fn stop_xvfb(pid: u32) {
    let _ = Command::new("kill").arg(pid.to_string()).output();
}
