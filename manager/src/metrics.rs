use serde::Serialize;
use sysinfo::{Disks, Networks, System};

#[derive(Debug, Clone, Serialize)]
pub struct SystemMetrics {
    pub cpu_usage: f32,
    pub memory_used: u64,
    pub memory_total: u64,
    pub disk_used: u64,
    pub disk_total: u64,
    pub net_rx_bytes: u64,
    pub net_tx_bytes: u64,
}

pub fn collect_system_metrics() -> SystemMetrics {
    let mut sys = System::new();
    sys.refresh_cpu_usage();
    sys.refresh_memory();

    let disks = Disks::new_with_refreshed_list();
    let (disk_used, disk_total) = disks.list().iter().fold((0u64, 0u64), |(used, total), d| {
        (
            used + d.total_space() - d.available_space(),
            total + d.total_space(),
        )
    });

    let networks = Networks::new_with_refreshed_list();
    let (rx, tx) = networks
        .list()
        .iter()
        .fold((0u64, 0u64), |(rx, tx), (_, data)| {
            (rx + data.total_received(), tx + data.total_transmitted())
        });

    SystemMetrics {
        cpu_usage: sys.global_cpu_usage(),
        memory_used: sys.used_memory(),
        memory_total: sys.total_memory(),
        disk_used,
        disk_total,
        net_rx_bytes: rx,
        net_tx_bytes: tx,
    }
}

/// Claude session metrics parsed from JSONL files
#[derive(Debug, Default, Clone, Serialize)]
pub struct ClaudeMetrics {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
    pub message_count: u64,
    pub tool_use_count: u64,
}

/// Parse Claude metrics from JSONL session files for a given project directory.
///
/// Claude stores JSONL in ~/.claude/projects/<encoded-path>/<session-id>.jsonl
/// where path encoding replaces `/` with `-`: /path/to/project → -path-to-project
pub fn parse_claude_metrics(project_dir: &str) -> Option<ClaudeMetrics> {
    let encoded = project_dir.replace('/', "-");
    let home = std::env::var("HOME").ok()?;
    let claude_dir = std::path::PathBuf::from(home)
        .join(".claude")
        .join("projects")
        .join(&encoded);

    if !claude_dir.exists() {
        return None;
    }

    // Find the most recent JSONL file
    let mut latest: Option<(std::time::SystemTime, std::path::PathBuf)> = None;
    for entry in std::fs::read_dir(&claude_dir).ok()? {
        let entry = entry.ok()?;
        let path = entry.path();
        if path.extension().map(|e| e == "jsonl").unwrap_or(false) {
            if let Ok(meta) = entry.metadata() {
                if let Ok(modified) = meta.modified() {
                    match &latest {
                        None => latest = Some((modified, path)),
                        Some((prev, _)) if modified > *prev => latest = Some((modified, path)),
                        _ => {}
                    }
                }
            }
        }
    }

    let (_, jsonl_path) = latest?;
    let contents = std::fs::read_to_string(&jsonl_path).ok()?;

    let mut metrics = ClaudeMetrics::default();
    for line in contents.lines() {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let msg_type = match v.get("type").and_then(|t| t.as_str()) {
            Some(t) => t,
            None => continue,
        };

        match msg_type {
            "assistant" => {
                if let Some(usage) = v.pointer("/message/usage") {
                    metrics.input_tokens +=
                        usage.get("input_tokens").and_then(|v| v.as_u64()).unwrap_or(0);
                    metrics.output_tokens += usage
                        .get("output_tokens")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    metrics.cache_creation_tokens += usage
                        .get("cache_creation_input_tokens")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                    metrics.cache_read_tokens += usage
                        .get("cache_read_input_tokens")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0);
                }
                if let Some(content) = v.pointer("/message/content").and_then(|c| c.as_array()) {
                    for block in content {
                        if block.get("type").and_then(|t| t.as_str()) == Some("tool_use") {
                            metrics.tool_use_count += 1;
                        }
                    }
                }
            }
            "user" => {
                metrics.message_count += 1;
            }
            _ => {}
        }
    }

    Some(metrics)
}
