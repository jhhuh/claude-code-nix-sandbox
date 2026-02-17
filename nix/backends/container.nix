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
          openssh
          coreutils
          bash
          nix
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

    if [[ $# -lt 1 ]] || [[ "''${1:-}" == "--help" ]] || [[ "''${1:-}" == "-h" ]]; then
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

    # Create ephemeral container root (suffix used for unique machine name)
    container_root="$(mktemp -d /tmp/claude-nspawn.XXXXXX)"
    machine_name="claude-sandbox-''${container_root##*.}"
    trap 'rm -rf "$container_root"' EXIT

    mkdir -p "$container_root"/{etc,var/lib,run,tmp}

    # Stub files required by nspawn
    touch "$container_root/etc/os-release"
    touch "$container_root/etc/machine-id"

    # Resolve real user's UID/GID/home/name (handles sudo)
    real_uid="$(id -u "''${SUDO_USER:-''${USER}}")"
    real_gid="$(id -g "''${SUDO_USER:-''${USER}}")"
    real_home="''${SUDO_HOME:-''${HOME}}"
    real_user="''${SUDO_USER:-''${USER}}"

    # Create sandbox user with the real user's UID/GID so file ownership matches
    echo "root:x:0:0:root:/root:/bin/bash" > "$container_root/etc/passwd"
    echo "sandbox:x:$real_uid:$real_gid:sandbox:$real_home:/bin/bash" >> "$container_root/etc/passwd"
    echo "root:x:0:" > "$container_root/etc/group"
    echo "sandbox:x:$real_gid:" >> "$container_root/etc/group"
    mkdir -p "$container_root$real_home"
    mkdir -p "$container_root$project_dir"
    chown -R "$real_uid:$real_gid" "$container_root$real_home"

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
    xauth_file="''${XAUTHORITY:-$real_home/.Xauthority}"
    if [[ -e "$xauth_file" ]]; then
      # Copy Xauthority into the container root (bind-mount gets hidden by --ephemeral overlay)
      cp "$xauth_file" "$container_root$real_home/.Xauthority"
      chmod 644 "$container_root$real_home/.Xauthority"
      xauth_args+=(--setenv=XAUTHORITY="$real_home/.Xauthority")
      # Set container hostname to match the Xauthority cookie (keyed by hostname)
      xauth_args+=("--hostname=$(hostname)")
    fi

    wayland_args=()
    runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u "$real_user")}"
    wayland_display="''${WAYLAND_DISPLAY:-}"
    if [[ -n "$wayland_display" ]] && [[ -e "$runtime_dir/$wayland_display" ]]; then
      wayland_args+=("--bind-ro=$runtime_dir/$wayland_display:/run/user/$real_uid/$wayland_display")
      wayland_args+=("--setenv=WAYLAND_DISPLAY=$wayland_display")
      wayland_args+=("--setenv=XDG_RUNTIME_DIR=/run/user/$real_uid")
    fi

    # D-Bus forwarding
    dbus_args=()
    if [[ -S "$runtime_dir/bus" ]]; then
      dbus_args+=("--bind-ro=$runtime_dir/bus:/run/user/$real_uid/bus")
      dbus_args+=("--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$real_uid/bus")
      dbus_args+=("--setenv=XDG_RUNTIME_DIR=/run/user/$real_uid")
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

    # Audio forwarding (PipeWire and PulseAudio)
    audio_args=()
    if [[ -e "$runtime_dir/pipewire-0" ]]; then
      audio_args+=("--bind-ro=$runtime_dir/pipewire-0:/run/user/$real_uid/pipewire-0")
    fi
    if [[ -e "$runtime_dir/pulse/native" ]]; then
      audio_args+=("--bind-ro=$runtime_dir/pulse:/run/user/$real_uid/pulse")
    fi

    # Claude auth persistence
    claude_auth_args=()
    host_claude_dir="$real_home/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      claude_auth_args+=(--bind="$host_claude_dir":"$real_home/.claude")
    fi

    # Git and SSH forwarding (read-only)
    git_args=()
    if [[ -f "$real_home/.gitconfig" ]]; then
      git_args+=(--bind-ro="$real_home/.gitconfig":"$real_home/.gitconfig")
    fi
    if [[ -d "$real_home/.config/git" ]]; then
      mkdir -p "$container_root$real_home/.config/git"
      git_args+=(--bind-ro="$real_home/.config/git":"$real_home/.config/git")
    fi
    if [[ -d "$real_home/.ssh" ]]; then
      git_args+=(--bind-ro="$real_home/.ssh":"$real_home/.ssh")
    fi
    ssh_agent_args=()
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]] && [[ -e "$SSH_AUTH_SOCK" ]]; then
      ssh_agent_args+=("--bind-ro=$SSH_AUTH_SOCK:/run/user/$real_uid/ssh-agent.sock")
      ssh_agent_args+=("--setenv=SSH_AUTH_SOCK=/run/user/$real_uid/ssh-agent.sock")
    fi

    # Network
    network_args=()
    ${lib.optionalString (!network) ''network_args+=(--private-network)''}

    # Select entrypoint and console mode
    console_args=()
    if [[ "$shell_mode" == true ]]; then
      entrypoint_args=(--setenv=ENTRYPOINT=bash)
    else
      entrypoint_args=(--setenv=ENTRYPOINT="$(printf '%q ' claude "$@")")
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

    # Host config forwarding (DNS, TLS, fonts, timezone, locale)
    host_cfg_args=()
    for f in /etc/resolv.conf /etc/hosts /etc/ssl /etc/ca-certificates /etc/pki \
             /etc/fonts /etc/localtime /etc/zoneinfo /etc/locale.conf \
             /etc/nix /etc/static /etc/nsswitch.conf; do
      if [[ -e "$f" ]]; then
        host_cfg_args+=("--bind-ro=$f")
      fi
    done

    # Nix store forwarding (conditional for non-NixOS hosts)
    nix_args=(--bind-ro=/nix/store)
    if [[ -d /nix/var/nix/db ]]; then
      nix_args+=(--bind-ro=/nix/var/nix/db)
    fi
    if [[ -d /nix/var/nix/daemon-socket ]]; then
      nix_args+=(--bind=/nix/var/nix/daemon-socket)
    fi

    exec systemd-nspawn \
      --quiet \
      --ephemeral \
      -M "$machine_name" \
      -D "$container_root" \
      "''${nix_args[@]}" \
      --bind="$project_dir":"$project_dir" \
      "''${host_cfg_args[@]}" \
      "''${display_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      "''${gpu_args[@]}" \
      "''${audio_args[@]}" \
      "''${claude_auth_args[@]}" \
      "''${git_args[@]}" \
      "''${ssh_agent_args[@]}" \
      "''${network_args[@]}" \
      "''${api_key_args[@]}" \
      "''${entrypoint_args[@]}" \
      "''${console_args[@]}" \
      --setenv=HOME="$real_home" \
      --setenv=PATH="${toplevel}/sw/bin" \
      --setenv=TERM="''${TERM:-xterm-256color}" \
      --setenv=NIX_REMOTE=daemon \
      --as-pid2 \
      -- "${toplevel}/sw/bin/bash" -c "chown $real_uid:$real_gid $project_dir && exec ${toplevel}/sw/bin/setpriv --reuid=$real_uid --regid=$real_gid --init-groups -- ${toplevel}/sw/bin/bash -c 'cd $project_dir && eval exec \$ENTRYPOINT'"
  '';
}
