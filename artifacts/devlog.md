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

