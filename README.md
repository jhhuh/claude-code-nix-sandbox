# claude-code-nix-sandbox

Launch sandboxed [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code) sessions with Chromium using Nix.

Claude Code runs inside an isolated sandbox with filesystem isolation, display forwarding, and a Chromium browser — all from nixpkgs. Three backends available with increasing isolation: [bubblewrap](https://github.com/containers/bubblewrap) (unprivileged), [systemd-nspawn](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html) (root), and QEMU VM (strongest).

## Quick Start

### Bubblewrap (unprivileged)

```bash
# Run Claude Code in a sandbox
nix run github:jhhuh/claude-code-nix-sandbox -- /path/to/project

# Drop into a shell inside the sandbox
nix run github:jhhuh/claude-code-nix-sandbox -- --shell /path/to/project
```

### systemd-nspawn container (requires sudo)

```bash
# Build the container package
nix build github:jhhuh/claude-code-nix-sandbox#container

# Run Claude Code in an nspawn container
sudo ./result/bin/claude-sandbox-container /path/to/project

# Shell mode
sudo ./result/bin/claude-sandbox-container --shell /path/to/project
```

### QEMU VM (strongest isolation)

```bash
# Build the VM package
nix build github:jhhuh/claude-code-nix-sandbox#vm

# Run Claude Code in a VM (serial console in terminal, Chromium in QEMU window)
./result/bin/claude-sandbox-vm /path/to/project

# Shell mode
./result/bin/claude-sandbox-vm --shell /path/to/project
```

Requires `ANTHROPIC_API_KEY` in your environment, or an existing `~/.claude` login (auto-mounted).

## What's Sandboxed

| Resource | Bubblewrap | Container | VM |
|---|---|---|---|
| Project directory | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (9p) |
| `~/.claude` | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (9p) |
| `/nix/store` | Read-only | Read-only | Shared from host |
| `/home` | Isolated (tmpfs) | Isolated | Separate filesystem |
| Network | Shared by default | Shared by default | NAT by default |
| Display | Host X11/Wayland | Host X11/Wayland | QEMU window (Xorg) |
| GPU (DRI) | Forwarded | Forwarded | Virtio VGA |
| D-Bus | Forwarded | Forwarded | Isolated |
| Kernel | Shared | Shared | Separate |

## Packages

| Package | Backend | Network | Requires |
|---|---|---|---|
| `default` | Bubblewrap | Full | User namespaces |
| `no-network` | Bubblewrap | Isolated | User namespaces |
| `container` | systemd-nspawn | Full | root (sudo) |
| `container-no-network` | systemd-nspawn | Isolated | root (sudo) |
| `vm` | QEMU | NAT | KVM recommended |
| `vm-no-network` | QEMU | Isolated | KVM recommended |

## NixOS Module

For NixOS users, a declarative module is available:

```nix
# flake.nix
{
  inputs.claude-sandbox.url = "github:jhhuh/claude-code-nix-sandbox";

  outputs = { nixpkgs, claude-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-sandbox.nixosModules.default
        {
          services.claude-sandbox = {
            enable = true;           # Install bubblewrap backend (default)
            container.enable = true; # Also install container backend
            vm.enable = true;        # Also install VM backend
            network = true;          # Allow network access (default)
          };
        }
      ];
    };
  };
}
```

## Requirements

- NixOS or Nix with flakes enabled
- Linux (bubblewrap requires user namespaces)
- X11 or Wayland display server (bubblewrap/container)
- KVM recommended for VM backend (`/dev/kvm`)
