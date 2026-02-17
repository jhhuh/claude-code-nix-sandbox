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

