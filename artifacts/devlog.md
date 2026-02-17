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

