# Dev Journal — claude-code-nix-sandbox

## 2026-02-17 — Initial scaffolding + bubblewrap backend

Scaffolded flake.nix, directory structure, CLAUDE.md. Built the bubblewrap sandbox backend (`nix/backends/bubblewrap.nix`) as a `writeShellApplication` wrapping `bwrap`.

Key decisions:
- `symlinkJoin` to build a unified PATH from packages (claude-code, chromium, coreutils, bash, git)
- Dynamic bash arrays for optional flags (display, D-Bus, GPU, auth, network) — cleaner than inline conditionals
- `--die-with-parent` so sandbox dies if launcher exits
- Project dir bound read-write at its real path, everything else isolated

Iterated on D-Bus forwarding (Chromium needs session bus), GPU/DRI forwarding (`/dev/dri` + `/run/opengl-driver` on NixOS), and Xauthority handling.

Added `--shell` mode and `~/.claude` bind-mount for auth persistence across sessions.

## 2026-02-17 — systemd-nspawn container backend

Built `nix/backends/container.nix` using `nixosSystem` to evaluate a NixOS config and get a system closure (`toplevel`). Creates an ephemeral container root at runtime with `/etc/passwd`, `/etc/group`, `/etc/nsswitch.conf` stubs.

**Problem**: `runuser`/`su` fail inside the container because PAM is not available (no `/etc/pam.d`).
**Fix**: Replaced with `setpriv --reuid=1000 --regid=1000 --init-groups` which drops privileges without PAM. See skill file: `nspawn-privilege-drop-without-pam.md`.

**Problem**: `--console=pipe` was always set for non-shell mode, breaking interactive TTY sessions.
**Fix**: Only use `--console=pipe` when `! -t 0` (stdin is not a terminal).

Added D-Bus session bus address env var, host config forwarding (DNS, TLS, fonts, timezone).

## 2026-02-17 — QEMU VM backend

Built `nix/backends/vm.nix` — full NixOS VM with QEMU, 4GB RAM, 4 cores.

Design: claude-code runs on serial console (user's terminal), Chromium renders in QEMU GTK window via Xorg+openbox. Project dir shared via 9p virtfs.

**Problem**: No serial output from VM — QEMU wasn't started with `-serial` flag.
**Fix**: Added `-serial stdio` to `virtualisation.qemu.options`.

**Problem**: Serial console wasn't primary — Linux `console=` had `tty0` last.
**Fix**: Reversed order via `virtualisation.qemu.consoles = [ "tty0" "ttyS0,115200n8" ]`. See skill file: `nixos-qemu-vm-serial-console-setup.md`.

**Problem**: Custom systemd service on ttyS0 had TTY management issues (TTYReset, ordering).
**Fix**: Replaced with NixOS built-in `services.getty.autologinUser` + `environment.interactiveShellInit` that checks `$(tty) == /dev/ttyS0`.

Tested: Chromium headless DOM dump works, uid=1000, version confirmed.

## 2026-02-17 — NixOS module + flake checks

Added `nix/modules/sandbox.nix` — declarative NixOS module with `services.claude-sandbox` options (enable, network, bubblewrap/container/vm toggles). Sets `security.unprivilegedUsernsClone = true` for bubblewrap.

Added `checks` output to flake.nix referencing all packages for CI validation.

## 2026-02-17 — Nix-daemon forwarding in sandboxes

User asked: "Shouldn't we bind mount host nix-daemon socket so that we can build something inside vm/container?"

Added `/nix/var/nix/daemon-socket` bind-mount to bubblewrap and container backends.

**Problem**: Read-only bind of unix socket fails (Permission denied).
**Fix**: Changed to read-write bind for the daemon socket.

**Problem**: `nix eval` tried to access `/nix/var/nix/db/big-lock` directly instead of going through daemon.
**Fix**: Set `NIX_REMOTE=daemon` env var to force daemon mode. Also added `nix` package to sandbox PATH. See skill file: `nix-daemon-socket-forwarding-in-sandboxes.md`.

Verified: `nix eval nixpkgs#hello.name` returns `"hello-2.12.1"` inside bubblewrap sandbox.

## 2026-02-17 — Bug fixes and feature audit

Ran a systematic comparison of all three backends. Found and fixed:

**Bugs fixed:**
- Container nix daemon socket was bound read-only (`--bind-ro`), preventing `nix` from connecting. Changed to `--bind`.
- Bubblewrap unconditionally set empty env vars (DISPLAY, WAYLAND_DISPLAY, XAUTHORITY, DBUS_SESSION_BUS_ADDRESS, ANTHROPIC_API_KEY). Made conditional — only set when non-empty on host.
- Container and VM entrypoint quoting: `exec $ENTRYPOINT` word-split on spaces. Fixed with `printf '%q'` + `eval exec`.
- VM hardcoded disk image path `/tmp/claude-sandbox-vm.qcow2` caused collisions between concurrent runs. Now uses `mktemp` + `NIX_DISK_IMAGE` env var.
- Container pre-created `.claude` dir even when host dir was absent. Removed from unconditional `mkdir`.

**Consistency fixes:**
- Added `nix` package to VM's `environment.systemPackages` (was missing, unlike bwrap/container).

**New features:**
- PipeWire and PulseAudio audio forwarding for bubblewrap and container. Forwards `pipewire-0` and `pulse/native` sockets.
- Git config (`~/.gitconfig`) and SSH key (`~/.ssh`) forwarding (read-only) to all three backends. SSH agent socket forwarded via `SSH_AUTH_SOCK`.
- GitHub Actions CI: `.github/workflows/ci.yml` runs `nix flake check` on push/PR.

**Further hardening:**
- Container machine name now uses unique suffix from mktemp to prevent collisions between concurrent nspawn instances.
- Container nix db/daemon-socket binds made conditional (was hard-failing on systems without these paths).
- Locale forwarding added: LANG, LC_ALL env vars and `/etc/locale.conf` for both bubblewrap and container.
- home-manager git config support: forward `~/.config/git/` in addition to `~/.gitconfig` (all three backends).
- Forward `/etc/nsswitch.conf` into bubblewrap for proper NSS-based lookups.

Verified: git config, SSH keys, locale, nix all work correctly inside bubblewrap sandbox.

## 2026-02-17 — UID mapping and remaining consistency

**Container UID mapping**: Replaced all hardcoded uid 1000 references with dynamic detection via `id -u "${SUDO_USER:-${USER}}"`. The container now creates the sandbox user with the real invoking user's UID/GID, preventing file ownership mismatches when the host user is not uid 1000. Affected: `/etc/passwd`, `/etc/group`, `setpriv` args, `chown`, and all `/run/user/` paths.

**Container config alignment**: Forwarded `/etc/nix`, `/etc/static`, `/etc/nsswitch.conf` into container to match bubblewrap's host config forwarding.

ShellCheck caught unquoted `$real_uid` inside array assignments — all instances quoted to pass `writeShellApplication` validation.

## 2026-02-17 — Polish and completeness

**openssh**: Added `openssh` to all three backends' package lists. Git SSH transport (`git push/pull` over SSH) was silently failing because `ssh` wasn't on PATH inside the sandbox.

**CI improvement**: Split GitHub Actions into two jobs — `build` (matrix: default, no-network) actually builds the bubblewrap variants; `eval` evaluates all packages and the NixOS module without full build. Container/VM packages build entire NixOS systems and are too expensive for CI free tier.

**CLI UX**: Added `--help`/`-h` flag to all three backends with consistent usage messages.

**NixOS module**: Added `bubblewrap.extraPackages`, `container.extraModules`, and `vm.extraModules` options to match the customization interface available via direct `callPackage`. README updated with commented examples.

**Documentation**: README updated with git/SSH/nix/locale forwarding details, `extraPackages`/`extraModules` customization section, NixOS module examples.

## 2026-02-17 — Add project sync to claude-remote CLI

Added `sync` and `watch` commands to `claude-remote` for syncing project directories to/from the remote server. Also added `--sync` flag to `create` for one-shot sync before sandbox creation.

- `sync <dir> [remote]`: one-shot rsync local→remote, excludes `.git/`, respects `.gitignore`
- `watch <dir> [remote]`: continuous bidirectional sync — fswatch for local→remote (with event debouncing), background rsync loop every 2s for remote→local (picks up Claude's modifications)
- `create --sync`: runs one-shot sync before calling the create API
- Added `rsync` and `fswatch` to `runtimeInputs` in `scripts/claude-remote.nix`

## 2026-02-17 — NixOS VM integration test for remote manager

Added `tests/manager.nix` — a `nixosTest` that exercises the full manager API lifecycle in a QEMU VM. Uses a stub `claude-sandbox` (`sleep 300`) to avoid needing the real backend.

Test covers: service startup, empty list, system metrics, create sandbox, list with one entry, stop, verify stopped, delete, verify empty, state.json validity. All 9 steps pass in ~13s.

Key details:
- `pkgs.testers.nixosTest` (not `pkgs.nixosTest` — removed from nixpkgs)
- Stub added via `sandboxPackages` module option (goes to systemd `path`)
- Set `SHELL=${pkgs.bash}/bin/bash` in service environment — system user defaults to nologin, which breaks tmux session creation
- Wired into flake `checks` as `manager-test`, runnable via `nix build .#checks.x86_64-linux.manager-test -L`
- Noted deprecation warning: `xorg.xorgserver` → `xorg-server` (in `package.nix`, not fixed here)

## 2026-02-17 — Documentation site with mdBook + GitHub Pages

Added a full documentation site using mdBook:

- `docs/` directory with `book.toml`, `SUMMARY.md`, and 14 content pages covering all backends, remote manager (CLI, API, dashboard), NixOS modules, customization, and architecture
- `packages.docs` in flake.nix — `stdenv.mkDerivation` with `mdbook build`
- `.github/workflows/docs.yml` — builds via Nix, deploys to GitHub Pages using `actions/deploy-pages`
- Content derived from README + source code reading (backends, modules, manager Rust source, CLI)
- Verified: `nix build .#docs` succeeds, `nix flake check` passes (docs included in checks)

## 2026-02-18 — Config file support for claude-remote CLI

Added config file loading to `claude-remote` so users don't need to export env vars in every shell session.

- Config location: `${XDG_CONFIG_HOME:-~/.config}/claude-remote/config`
- Format: simple `key = value` lines, comments with `#`, blank lines ignored
- Supported keys: `host`, `port`, `ssh_opts`
- Precedence: env var > config file > default
- Pure bash parsing (no extra deps) — `while read` loop with `%%`/`#` parameter expansion for key/value splitting
- Updated help text to show config file location and example
- Updated mdBook docs (`docs/src/remote-manager/cli.md`) with config file section
- Nix escaping gotcha: `${...}` in comments inside `''` strings is still interpolated by Nix — must use `''${` escape even in bash comments

## 2026-02-18 — Switch claude-code to sadjow/claude-code-nix

Replaced nixpkgs' `claude-code` with the package from `github:sadjow/claude-code-nix`.

- Added `claude-code-nix` flake input with `inputs.nixpkgs.follows = "nixpkgs"` to share the same nixpkgs
- Applied `claude-code-nix.overlays.default` to `pkgsFor` so `pkgs.claude-code` resolves from the flake for bubblewrap backend (via `callPackage`)
- Also injected the overlay into every `nixosSystem` call (container and VM backends) via `nixpkgs.overlays` module — without this, those NixOS evaluations would still pull `claude-code` from upstream nixpkgs
- Backend `.nix` files unchanged — they still reference `pkgs.claude-code`, which the overlay shadows
- Updated CLAUDE.md conventions section
- Updated docs: introduction mentions sadjow/claude-code-nix, customization flake input example shows the overlay, NixOS module docs softened `allowUnfree` note

## 2026-02-21 — Preserve host paths inside sandbox backends

Claude Code stores sessions in `~/.claude/projects/<encoded-path>/` where `<encoded-path>` is the project directory's absolute path with `/` replaced by `-`. When the sandbox uses synthetic paths (`/home/sandbox`, `/project`), Claude creates sessions under a different key and can't find existing host sessions.

**Bubblewrap**: Changed `sandbox_home="/home/sandbox"` → `sandbox_home="$HOME"`. Everything else cascades through the variable — bind mounts, `--setenv HOME`, `--dir`, etc.

**Container**: Moved `real_home`/`real_user` definitions up before `mkdir`. Replaced all `/home/sandbox` references with `$real_home` (passwd entry, Xauthority, .claude, .gitconfig, .config/git, .ssh bind targets). Replaced `/project` with `$project_dir` (bind mount, chown, cd, entrypoint).

**VM**: 9p mount points are baked at NixOS build time, so runtime fixups are needed. Launcher writes `$HOME` and `$project_dir` to meta dir. Added passwordless sudo (`wheel` group) for the sandbox user (VM is already fully isolated). `interactiveShellInit` reads host paths from `/mnt/meta/`, creates real home dir, symlinks dotfiles from `/home/sandbox/` to `$host_home/`, and bind-mounts `/project` to `$host_project`. Bind mount (not symlink) for project dir because `getcwd()` resolves symlinks but not bind mounts.

## 2026-02-24 — Knowledge catch-up: skill extraction and session tooling

Reviewed all git history and Claude Code session files to identify undocumented patterns. The devlog was already current with all commits — no missing entries.

**Session summarizer tool**: Built `artifacts/tools/session-summarizer.sh` — a jq/bash script that extracts human-readable conversation from Claude Code JSONL session files without loading multi-MB tool results into context. Modes: `--overview` (compact conversation), `--user-only` (just human messages), `--tools` (tool use frequency), `--commits` (git commits made). Key insight: session JSONL has `user`/`assistant`/`system`/`progress`/`queue-operation`/`file-history-snapshot` types; only `user` and `assistant` carry useful content, and assistant `tool_use` blocks are the bulk of file size.

**New skill files extracted** (7 total, from code patterns and session history):
- `nix-writeShellApplication-escaping-and-shellcheck.md` — the `''${` escape for bash vars in Nix strings, SC2155 (declare/assign separately), SC2029 (SSH vars)
- `vm-9p-runtime-path-fixup-for-session-continuity.md` — meta dir + bind-mount pattern for preserving host paths when 9p mounts are baked at build time
- `nix-overlay-injection-into-nixosSystem-calls.md` — overlays applied to `pkgsFor` don't propagate to `nixosSystem` calls; must inject via `nixpkgs.overlays` module
- `nixos-vm-integration-test-with-stub-services.md` — `pkgs.testers.nixosTest` (not `pkgs.nixosTest`), stub backends, system user shell gotcha
- `ssh-remote-cli-printf-q-escaping.md` — `printf '%q'` for SSH argument escaping
- `bubblewrap-dynamic-bash-arrays-for-optional-flags.md` — bash arrays for conditional bwrap flags (empty arrays expand to nothing)
- `claude-code-session-jsonl-extraction.md` — JSONL structure, jq extraction patterns, the summarizer tool

Updated CLAUDE.md skill files section with all new entries.

## 2026-02-27 — Sandbox hardening: auth, Chrome isolation, cleanup

Multiple fixes to sandbox backends for real-world multi-instance usage.

**Container ~/.claude not mounting**: `real_home` used `SUDO_HOME` which isn't a real env var. Under sudo with `env_reset`, `HOME=/root`, so the bind check for `/root/.claude` silently failed. Fixed by resolving home from `getent passwd` (consistent with how `real_uid`/`real_gid` already use `id(1)`).

**~/.claude.json forwarding**: Added to all three backends. Bubblewrap and container bind-mount it read-write; VM copies it into the meta dir.

**Security guide acceptance**: `~/.claude` is now always created on the host (`mkdir -p`) before bind-mounting, so first-run security acceptance persists. Previously the conditional `if [[ -d ]]` check meant first-run writes went to tmpfs and were lost.

**Chrome session stealing between sandboxes**: Two root causes identified and fixed:
1. Shared D-Bus session bus — Chromium registers `org.chromium.Chromium` on D-Bus, letting the second sandbox's Chrome discover the first. Removed session bus forwarding from both backends (system bus kept for NetworkManager etc.)
2. Shared CDP port — both Chromium instances bind to the same default debugging port on the shared network namespace. Fixed by using per-project Chromium profiles: `<project-dir>/.config/chromium/` is created and mounted as `~/.config/chromium` inside the sandbox. Each project gets isolated CDP sockets.

**`/usr/bin/env`**: Added to bubblewrap (`--dir /usr/bin --ro-bind-try`) and container (`ln -s ${toplevel}/sw/bin/env`). Scripts with `#!/usr/bin/env` shebangs now work.

**GitHub CLI forwarding**: `~/.config/gh` always bind-mounted read-only (like gitconfig). New `--gh-token` flag opts into forwarding `GH_TOKEN`/`GITHUB_TOKEN` env vars. Flag parsing upgraded to `while` loop supporting multiple `--` options in both backends.

**Stale temp dir cleanup**: Container and VM backends now sweep orphaned `/tmp/claude-nspawn.*` and `/tmp/claude-vm-meta.*` dirs on startup. Container checks `machinectl show` to skip running instances; VM uses `fuser` to skip in-use disk images.

