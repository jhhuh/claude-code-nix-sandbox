# Bubblewrap Backend

The default backend. Uses [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) to create a lightweight sandbox using Linux user namespaces. No root required.

## Usage

```bash
# Build
nix build github:jhhuh/claude-code-nix-sandbox

# Run
./result/bin/claude-sandbox /path/to/project
./result/bin/claude-sandbox --shell /path/to/project

# Without network
nix build github:jhhuh/claude-code-nix-sandbox#no-network
./result/bin/claude-sandbox /path/to/project
```

## How it works

The sandbox script builds a `symlinkJoin` of all packages (claude-code, chromium, git, openssh, nix, coreutils, bash, plus any `extraPackages`) into a single PATH. It then calls `bwrap` with:

- **Filesystem**: `/nix/store` read-only, project directory read-write, `~/.claude` read-write, `/home` as tmpfs
- **Display**: X11 socket + Xauthority, Wayland socket forwarded
- **D-Bus**: session bus and system bus sockets forwarded (needed by Chromium)
- **GPU**: `/dev/dri` and `/run/opengl-driver` forwarded for hardware acceleration
- **Audio**: PipeWire and PulseAudio sockets forwarded
- **Network**: shared with host by default, `--unshare-net` when `network = false`
- **Nix**: daemon socket forwarded with `NIX_REMOTE=daemon`

The sandbox home is `/home/sandbox`. The process runs as your user (no UID mapping).

## Nix parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `network` | bool | `true` | Allow network access (false adds `--unshare-net`) |
| `extraPackages` | list of packages | `[]` | Additional packages on PATH inside the sandbox |

## Customization example

```nix
pkgs.callPackage ./nix/backends/bubblewrap.nix {
  extraPackages = [ pkgs.python3 pkgs.nodejs ];
  network = false;
}
```

## Requirements

- Linux with user namespace support (`security.unprivilegedUsernsClone = true` on NixOS)
- X11 or Wayland display server
