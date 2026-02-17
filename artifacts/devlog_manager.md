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

## 2026-02-17: Local testing and bug fixes

**CLI SSH quoting bug (a68d9f7):**
- `remote_api` passed curl args as separate SSH arguments. SSH concatenates them into a single string for the remote shell, so JSON payloads with `{}:` were parsed as bash commands.
- Fix: use `printf '%q'` to escape each argument before building the SSH command string.
- Also needed `# shellcheck disable=SC2029` — `writeShellApplication` treats SC2029 (info) as error.

**Sandbox immediately dead (ad15ff2):**
- Manager spawns backend inside tmux (`claude-sandbox /tmp/test`), but `claude-sandbox` wasn't on the manager's PATH.
- Fix: added `sandboxPackages` parameter to `package.nix`, passed bubblewrap backend from `flake.nix`. Nix deduplicates the derivation so it's not built twice.

**Local testing results:**
- Manager served on port 3001 (3000 was occupied).
- All endpoints verified: dashboard HTML, new sandbox form, JSON CRUD API, system metrics, htmx fragments, static files.
- Created sandbox via CLI and curl — tmux session stayed alive, status remained `running`.
- `tmux attach -t sandbox-<short-id>` connects to the Claude session inside the sandbox.

## 2026-02-17: DevShell and CLI polish

**CLI in devShell (1dd2eb5):**
- Added `claude-remote` to the default `devShell` so it's available via direnv without `nix run .#cli`.

**Help without CLAUDE_REMOTE_HOST (6d8cf20):**
- `claude-remote help` (and `--help`, `-h`, no args) exited with "CLAUDE_REMOTE_HOST is not set" because the host check ran before command dispatch.
- Fix: check if the command is help-like before requiring the host env var.

## 2026-02-17: Flake check and cleanup

**CLAUDE.md updated (543cf91):**
- Documented full architecture tree including manager, CLI, NixOS module.
- Added manager commands to Common Commands section.
- Added manager-specific conventions (Rust/Axum stack, vendored htmx, SSH-based CLI).

**VM shellcheck fix (96b0280):**
- `nix flake check` failed on vm.nix: SC2155 warning on `export NIX_DISK_IMAGE="$(mktemp ...)"`.
- Pre-existing issue, not caused by manager changes. Fixed by splitting declare and assign.
- All 8 packages + 2 NixOS modules now pass `nix flake check`.

