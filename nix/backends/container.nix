# systemd-nspawn container backend for Claude Code + Chromium
#
# Usage: claude-sandbox-container [--shell] <project-dir> [claude args...]
#
# Launches a NixOS container via systemd-nspawn with claude-code and
# chromium. Requires root (sudo). Provides stronger isolation than
# bubblewrap: separate PID, mount, IPC, and optionally network namespaces.
{
  lib,
  writeShellApplication,
  systemd,
  coreutils,
  nixos,
  # Toggle host network access (set false for private network)
  network ? true,
  # Additional NixOS modules for the container
  extraModules ? [ ],
}:

let
  containerSystem = nixos {
    imports = [
      ({ pkgs, ... }: {
        boot.isNspawnContainer = true;

        networking.useDHCP = false;
        networking.hostName = "claude-sandbox";

        nixpkgs.config.allowUnfree = true;

        environment.systemPackages = with pkgs; [
          claude-code
          chromium
          git
          coreutils
          bash
          util-linux  # setpriv for privilege dropping
        ];

        system.stateVersion = "24.11";
      })
    ] ++ extraModules;
  };

  toplevel = containerSystem.config.system.build.toplevel;
in
writeShellApplication {
  name = "claude-sandbox-container";
  runtimeInputs = [ systemd coreutils ];

  text = ''
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "Error: systemd-nspawn requires root. Run with sudo." >&2
      exit 1
    fi

    shell_mode=false
    if [[ "''${1:-}" == "--shell" ]]; then
      shell_mode=true
      shift
    fi

    if [[ $# -lt 1 ]]; then
      echo "Usage: sudo claude-sandbox-container [--shell] <project-dir> [claude args...]" >&2
      echo "  --shell  Drop into bash instead of launching claude" >&2
      exit 1
    fi

    project_dir="$(realpath "$1")"
    shift

    if [[ ! -d "$project_dir" ]]; then
      echo "Error: $project_dir is not a directory" >&2
      exit 1
    fi

    # Create ephemeral container root
    container_root="$(mktemp -d /tmp/claude-nspawn.XXXXXX)"
    trap 'rm -rf "$container_root"' EXIT

    mkdir -p "$container_root"/{etc,var/lib,run,tmp,home/sandbox/.claude,project}

    # Stub files required by nspawn
    touch "$container_root/etc/os-release"
    touch "$container_root/etc/machine-id"

    # Create sandbox user (uid 1000) so we can drop privileges
    echo "root:x:0:0:root:/root:/bin/bash" > "$container_root/etc/passwd"
    echo "sandbox:x:1000:1000:sandbox:/home/sandbox:/bin/bash" >> "$container_root/etc/passwd"
    echo "root:x:0:" > "$container_root/etc/group"
    echo "sandbox:x:1000:" >> "$container_root/etc/group"
    chown -R 1000:1000 "$container_root/home/sandbox"

    # NSS config for username resolution
    echo "passwd: files" > "$container_root/etc/nsswitch.conf"
    echo "group: files" >> "$container_root/etc/nsswitch.conf"

    # Display forwarding args
    display_args=()
    if [[ -n "''${DISPLAY:-}" ]]; then
      display_args+=(--bind-ro=/tmp/.X11-unix:/tmp/.X11-unix)
      display_args+=(--setenv=DISPLAY="$DISPLAY")
    fi

    xauth_args=()
    real_home="''${SUDO_HOME:-''${HOME}}"
    real_user="''${SUDO_USER:-''${USER}}"
    xauth_file="''${XAUTHORITY:-$real_home/.Xauthority}"
    if [[ -e "$xauth_file" ]]; then
      # Copy Xauthority into the container root (bind-mount gets hidden by --ephemeral overlay)
      cp "$xauth_file" "$container_root/home/sandbox/.Xauthority"
      chmod 644 "$container_root/home/sandbox/.Xauthority"
      xauth_args+=(--setenv=XAUTHORITY=/home/sandbox/.Xauthority)
      # Set container hostname to match the Xauthority cookie (keyed by hostname)
      xauth_args+=("--hostname=$(hostname)")
    fi

    wayland_args=()
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u "$real_user")}"
    wayland_display="''${WAYLAND_DISPLAY:-}"
    if [[ -n "$wayland_display" ]] && [[ -e "$runtime_dir/$wayland_display" ]]; then
      wayland_args+=("--bind-ro=$runtime_dir/$wayland_display:/run/user/1000/$wayland_display")
      wayland_args+=("--setenv=WAYLAND_DISPLAY=$wayland_display")
      wayland_args+=(--setenv=XDG_RUNTIME_DIR=/run/user/1000)
    fi

    # D-Bus forwarding
    dbus_args=()
    if [[ -S "$runtime_dir/bus" ]]; then
      dbus_args+=(--bind-ro="$runtime_dir/bus":/run/user/1000/bus)
      dbus_args+=(--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
      dbus_args+=(--setenv=XDG_RUNTIME_DIR=/run/user/1000)
    fi
    if [[ -S /run/dbus/system_bus_socket ]]; then
      dbus_args+=(--bind-ro=/run/dbus/system_bus_socket)
    fi

    # GPU forwarding
    gpu_args=()
    if [[ -d /dev/dri ]]; then
      gpu_args+=(--bind=/dev/dri)
    fi
    if [[ -d /dev/shm ]]; then
      gpu_args+=(--bind=/dev/shm)
    fi
    if [[ -d /run/opengl-driver ]]; then
      gpu_args+=(--bind-ro=/run/opengl-driver)
    fi

    # Claude auth persistence
    claude_auth_args=()
    host_claude_dir="$real_home/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      claude_auth_args+=(--bind="$host_claude_dir":/home/sandbox/.claude)
    fi

    # Network
    network_args=()
    ${lib.optionalString (!network) ''network_args+=(--private-network)''}

    # Select entrypoint and console mode
    console_args=()
    if [[ "$shell_mode" == true ]]; then
      entrypoint_args=(--setenv=ENTRYPOINT=bash)
    else
      claude_args=("$@")
      entrypoint_args=(--setenv=ENTRYPOINT="claude ''${claude_args[*]}")
    fi
    # Use pipe console when stdin is not a terminal (e.g. piped commands, --version)
    if [[ ! -t 0 ]]; then
      console_args+=(--console=pipe)
    fi

    # API key
    api_key_args=()
    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      api_key_args+=(--setenv=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
    fi

    # Host config forwarding (DNS, TLS, fonts, timezone)
    host_cfg_args=()
    for f in /etc/resolv.conf /etc/hosts /etc/ssl /etc/ca-certificates /etc/pki \
             /etc/fonts /etc/localtime /etc/zoneinfo; do
      if [[ -e "$f" ]]; then
        host_cfg_args+=("--bind-ro=$f")
      fi
    done

    exec systemd-nspawn \
      --quiet \
      --ephemeral \
      -M claude-sandbox \
      -D "$container_root" \
      --bind-ro=/nix/store \
      --bind-ro=/nix/var/nix/db \
      --bind="$project_dir":/project \
      "''${host_cfg_args[@]}" \
      "''${display_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      "''${gpu_args[@]}" \
      "''${claude_auth_args[@]}" \
      "''${network_args[@]}" \
      "''${api_key_args[@]}" \
      "''${entrypoint_args[@]}" \
      "''${console_args[@]}" \
      --setenv=HOME=/home/sandbox \
      --setenv=PATH="${toplevel}/sw/bin" \
      --setenv=TERM="''${TERM:-xterm-256color}" \
      --as-pid2 \
      -- "${toplevel}/sw/bin/bash" -c "chown 1000:1000 /project && exec ${toplevel}/sw/bin/setpriv --reuid=1000 --regid=1000 --init-groups -- ${toplevel}/sw/bin/bash -c 'cd /project && exec \$ENTRYPOINT'"
  '';
}
