# Devlog: Remote Sandbox Manager

## 2026-02-17: Initial implementation (Phases 1-6)

**What was done:**
- Created full Rust/Axum web dashboard in `manager/`
- Implemented all 6 phases from the plan in one pass:
  - Phase 1 (Skeleton): Cargo.toml, main.rs, state types, stub handlers
  - Phase 2 (State + CRUD): JSON persistence, full CRUD API, HTML forms, askama templates
  - Phase 3 (Process management): Xvfb spawn/kill (display.rs), tmux session management (session.rs), sandbox lifecycle (sandbox.rs)
  - Phase 4 (Screenshots): Xvfb capture via ImageMagick `import`, QMP screendump for VM (screenshot.rs), background capture loop every 2s
  - Phase 5 (Metrics): sysinfo for system metrics, JSONL parser for Claude session metrics (metrics.rs), htmx fragment auto-refresh
  - Phase 6 (CLI + NixOS module): `scripts/claude-remote.nix` (SSH-based CLI), `nix/modules/manager.nix` (systemd service)
- Added `packages.{manager, cli}`, `nixosModules.manager`, `devShells.manager` to flake.nix
- Both `nix build .#manager` and `nix build .#cli` succeed
- Vendored htmx 2.0.4 in `manager/static/htmx.min.js`
- Dark-themed responsive CSS, no build step

**Key decisions:**
- axum 0.7 + tower-http 0.5 + askama 0.12 (stable ecosystem combo)
- tokio::sync::RwLock for shared state (read-heavy)
- JSON file persistence (simple, sufficient for single-server)
- Screenshots cached in-memory HashMap
- QMP screenshots via socat shell-out (avoids implementing protocol in Rust)
- Template status check uses `sandbox.is_running()` method (askama can't use `crate::` paths)

**Gotchas:**
- Nix flakes only see git-tracked files. Had to `git add` before `nix build` would find new files.
- askama templates can't reference Rust enum variants directly — need helper methods on the struct.

