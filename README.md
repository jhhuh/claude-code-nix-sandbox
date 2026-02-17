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

Git push/pull works inside all sandboxes — `~/.gitconfig`, `~/.config/git/`, `~/.ssh/`, and `SSH_AUTH_SOCK` are forwarded read-only. Nix commands work too (`NIX_REMOTE=daemon`).

## What's Sandboxed

| Resource | Bubblewrap | Container | VM |
|---|---|---|---|
| Project directory | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (9p) |
| `~/.claude` | Read-write (bind-mount) | Read-write (bind-mount) | Read-write (9p) |
| `~/.gitconfig`, `~/.ssh` | Read-only (bind-mount) | Read-only (bind-mount) | Read-only (9p) |
| `/nix/store` | Read-only | Read-only | Shared from host |
| `/home` | Isolated (tmpfs) | Isolated | Separate filesystem |
| Network | Shared by default | Shared by default | NAT by default |
| Display | Host X11/Wayland | Host X11/Wayland | QEMU window (Xorg) |
| Audio | PipeWire/PulseAudio | PipeWire/PulseAudio | Isolated |
| GPU (DRI) | Forwarded | Forwarded | Virtio VGA |
| D-Bus | Forwarded | Forwarded | Isolated |
| SSH agent | Forwarded | Forwarded | Isolated |
| Nix commands | Via daemon | Via daemon | Local store |
| Locale | Forwarded | Forwarded | NixOS default |
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
            # Extra packages inside bubblewrap sandbox:
            # bubblewrap.extraPackages = with pkgs; [ python3 nodejs ];
            # Extra NixOS modules for container/VM:
            # container.extraModules = [{ environment.systemPackages = with pkgs; [ python3 ]; }];
            # vm.extraModules = [{ environment.systemPackages = with pkgs; [ python3 ]; }];
          };
        }
      ];
    };
  };
}
```

## Customization

Add extra packages inside the sandbox via `extraPackages` (bubblewrap) or `extraModules` (container/VM):

```nix
# Add python3 and nodejs to the bubblewrap sandbox
packages.default = pkgs.callPackage ./nix/backends/bubblewrap.nix {
  extraPackages = [ pkgs.python3 pkgs.nodejs ];
};

# Add extra NixOS config to the container
packages.container = pkgs.callPackage ./nix/backends/container.nix {
  nixos = args: nixpkgs.lib.nixosSystem { system = "x86_64-linux"; modules = args.imports; };
  extraModules = [{ environment.systemPackages = [ pkgs.python3 ]; }];
};
```

## Requirements

- NixOS or Nix with flakes enabled
- Linux (bubblewrap requires user namespaces)
- X11 or Wayland display server (bubblewrap/container)
- KVM recommended for VM backend (`/dev/kvm`)
