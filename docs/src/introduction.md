# claude-code-nix-sandbox

> **Warning:** This project is under active development and should be considered unstable. Features may be incomplete, broken, or change without notice. If you choose to run it, you do so at your own risk. There are no guarantees of correctness, security, or fitness for any particular purpose.

Launch sandboxed [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code) sessions with Chromium using Nix.

Claude Code (from [sadjow/claude-code-nix](https://github.com/sadjow/claude-code-nix)) runs inside an isolated sandbox with filesystem isolation, display forwarding, and a Chromium browser. Three backends are available with increasing isolation strength:

| Backend | Isolation | Requires |
|---|---|---|
| [Bubblewrap](https://github.com/containers/bubblewrap) | User namespaces, shared kernel | Unprivileged |
| [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) | Full namespace isolation | Root (sudo) |
| QEMU VM | Separate kernel, hardware virtualization | KVM recommended |

A remote sandbox manager is also provided: a Rust/Axum daemon with a web dashboard and CLI for managing sandboxes on a server over SSH.

## Features

- **Pure Nix** — no shell/Python wrappers; all orchestration in Nix
- **Chromium from nixpkgs** — always `pkgs.chromium` inside the sandbox
- **Git/SSH forwarding** — push/pull works inside all backends
- **Nix commands** — `NIX_REMOTE=daemon` forwarding so `nix build` works inside sandboxes
- **Display forwarding** — X11, Wayland, GPU acceleration (bubblewrap/container) or QEMU window (VM)
- **Audio forwarding** — PipeWire/PulseAudio (bubblewrap/container)
- **Remote management** — web dashboard with live screenshots, metrics, and a CLI over SSH
