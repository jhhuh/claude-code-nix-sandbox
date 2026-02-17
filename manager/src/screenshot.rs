use std::process::Command;

/// Capture screenshot from an Xvfb display using ImageMagick's `import`
pub fn capture_xvfb(display_num: u32) -> Option<Vec<u8>> {
    let display = format!(":{}", display_num);
    let output = Command::new("import")
        .args(["-window", "root", "-display", &display, "png:-"])
        .output()
        .ok()?;
    if output.status.success() && !output.stdout.is_empty() {
        Some(output.stdout)
    } else {
        None
    }
}

/// Capture screenshot from a QEMU VM via QMP socket
pub fn capture_qmp(socket_path: &str) -> Option<Vec<u8>> {
    let tmp_ppm = format!("/tmp/qmp-screenshot-{}.ppm", std::process::id());

    // Send QMP commands over the unix socket via socat
    // Both commands go over a single connection
    let script = format!(
        r#"(echo '{{"execute":"qmp_capabilities"}}'; sleep 0.1; echo '{{"execute":"screendump","arguments":{{"filename":"{ppm}"}}}}'; sleep 0.5) | socat - UNIX-CONNECT:{sock}"#,
        ppm = tmp_ppm,
        sock = socket_path,
    );

    let _ = Command::new("bash").args(["-c", &script]).output().ok()?;

    // Convert PPM → PNG
    let output = Command::new("convert")
        .args([&tmp_ppm, "png:-"])
        .output()
        .ok()?;

    // Clean up temp file
    let _ = std::fs::remove_file(&tmp_ppm);

    if output.status.success() && !output.stdout.is_empty() {
        Some(output.stdout)
    } else {
        None
    }
}
