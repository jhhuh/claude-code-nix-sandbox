# Bubblewrap sandbox backend for Claude Code + Chromium
#
# Usage: claude-sandbox [--shell] <project-dir> [claude args...]
#
# Produces a writeShellApplication that wraps bwrap to isolate
# claude-code and chromium with access to a single project directory.
# Automatically bind-mounts ~/.claude for auth persistence if it exists.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  bubblewrap,
  claude-code,
  chromium,
  coreutils,
  bash,
  git,
  nix,
  # Toggle host network access (set false to --unshare-net)
  network ? true,
  # Additional packages available inside the sandbox
  extraPackages ? [ ],
}:

let
  sandboxPath = symlinkJoin {
    name = "claude-sandbox-path";
    paths = [
      claude-code
      chromium
      coreutils
      bash
      git
      nix
    ] ++ extraPackages;
  };

  networkFlags = lib.optionalString (!network) "--unshare-net";
in
writeShellApplication {
  name = "claude-sandbox";
  runtimeInputs = [ bubblewrap coreutils ];

  text = ''
    shell_mode=false
    if [[ "''${1:-}" == "--shell" ]]; then
      shell_mode=true
      shift
    fi

    if [[ $# -lt 1 ]]; then
      echo "Usage: claude-sandbox [--shell] <project-dir> [claude args...]" >&2
      echo "  --shell  Drop into bash instead of launching claude" >&2
      exit 1
    fi

    project_dir="$(realpath "$1")"
    shift

    if [[ ! -d "$project_dir" ]]; then
      echo "Error: $project_dir is not a directory" >&2
      exit 1
    fi

    # X11 display forwarding
    x11_args=()
    if [[ -n "''${DISPLAY:-}" ]] && [[ "$DISPLAY" == *:* ]]; then
      display_nr="''${DISPLAY/#*:}"
      display_nr="''${display_nr/%.*}"
      local_socket="/tmp/.X11-unix/X$display_nr"
      x11_args+=(--tmpfs /tmp/.X11-unix)
      x11_args+=(--ro-bind-try "$local_socket" "$local_socket")
    fi

    # Xauthority forwarding
    xauth_args=()
    if [[ -n "''${XAUTHORITY:-}" ]] && [[ -e "$XAUTHORITY" ]]; then
      xauth_args+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY")
    fi

    # Wayland forwarding
    wayland_args=()
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      wayland_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
      if [[ -e "$wayland_socket" ]]; then
        wayland_args+=(--ro-bind "$wayland_socket" "$wayland_socket")
      fi
    fi

    # D-Bus forwarding (needed by Chromium)
    dbus_args=()
    # Session bus via DBUS_SESSION_BUS_ADDRESS
    if [[ -n "''${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
      dbus_path=""
      if [[ "$DBUS_SESSION_BUS_ADDRESS" == unix:path=* ]]; then
        dbus_path="''${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
        dbus_path="''${dbus_path%%;*}"
      fi
      if [[ -n "$dbus_path" ]] && [[ -e "$dbus_path" ]]; then
        dbus_args+=(--ro-bind "$dbus_path" "$dbus_path")
      fi
    fi
    # XDG_RUNTIME_DIR/bus (user session bus fallback)
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]] && [[ -S "$XDG_RUNTIME_DIR/bus" ]]; then
      dbus_args+=(--ro-bind "$XDG_RUNTIME_DIR/bus" "$XDG_RUNTIME_DIR/bus")
    fi
    # System bus
    if [[ -S /run/dbus/system_bus_socket ]]; then
      dbus_args+=(--ro-bind /run/dbus/system_bus_socket /run/dbus/system_bus_socket)
    fi

    # DRI (GPU) forwarding for Chromium hardware acceleration
    dri_args=()
    if [[ -d /dev/dri ]]; then
      dri_args+=(--dev-bind /dev/dri /dev/dri)
    fi

    # OpenGL/Vulkan driver forwarding (NixOS puts drivers in /run/opengl-driver)
    gpu_args=()
    if [[ -d /run/opengl-driver ]]; then
      gpu_args+=(--ro-bind /run/opengl-driver /run/opengl-driver)
    fi

    # Determine sandbox home directory
    sandbox_home="/home/sandbox"

    # Prepare XDG_RUNTIME_DIR bind args (needs --dir before bind since /run is tmpfs)
    xdg_runtime_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      xdg_runtime_args+=(--dir "$XDG_RUNTIME_DIR")
    fi

    # Claude auth persistence: bind-mount ~/.claude if it exists
    claude_auth_args=()
    host_claude_dir="''${HOME}/.claude"
    if [[ -d "$host_claude_dir" ]]; then
      claude_auth_args+=(--bind "$host_claude_dir" "$sandbox_home/.claude")
    fi

    # Select entrypoint
    if [[ "$shell_mode" == true ]]; then
      entrypoint=(bash)
    else
      entrypoint=(claude "$@")
    fi

    exec bwrap \
      --die-with-parent \
      --proc /proc \
      --dev /dev \
      --dev-bind /dev/shm /dev/shm \
      "''${dri_args[@]}" \
      --ro-bind /nix/store /nix/store \
      --ro-bind-try /nix/var/nix/db /nix/var/nix/db \
      --bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket \
      --ro-bind-try /run/current-system/sw /run/current-system/sw \
      --tmpfs /tmp \
      --tmpfs /run \
      "''${xdg_runtime_args[@]}" \
      --dir /run/dbus \
      "''${gpu_args[@]}" \
      --tmpfs /home \
      --dir "$sandbox_home" \
      --dir "$sandbox_home/.config" \
      "''${claude_auth_args[@]}" \
      --bind "$project_dir" "$project_dir" \
      --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
      --ro-bind-try /etc/hosts /etc/hosts \
      --ro-bind-try /etc/ssl /etc/ssl \
      --ro-bind-try /etc/ca-certificates /etc/ca-certificates \
      --ro-bind-try /etc/pki /etc/pki \
      --ro-bind-try /etc/fonts /etc/fonts \
      --ro-bind-try /etc/passwd /etc/passwd \
      --ro-bind-try /etc/group /etc/group \
      --ro-bind-try /etc/localtime /etc/localtime \
      --ro-bind-try /etc/zoneinfo /etc/zoneinfo \
      --ro-bind-try /etc/machine-id /etc/machine-id \
      --ro-bind-try /etc/nix /etc/nix \
      --ro-bind-try /etc/static /etc/static \
      "''${x11_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      --setenv HOME "$sandbox_home" \
      --setenv PATH "${sandboxPath}/bin" \
      --setenv DISPLAY "''${DISPLAY:-}" \
      --setenv WAYLAND_DISPLAY "''${WAYLAND_DISPLAY:-}" \
      --setenv XAUTHORITY "''${XAUTHORITY:-}" \
      --setenv DBUS_SESSION_BUS_ADDRESS "''${DBUS_SESSION_BUS_ADDRESS:-}" \
      --setenv TERM "''${TERM:-xterm-256color}" \
      --setenv ANTHROPIC_API_KEY "''${ANTHROPIC_API_KEY:-}" \
      --setenv NIX_REMOTE daemon \
      --setenv XDG_RUNTIME_DIR "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
      --setenv XDG_CONFIG_HOME "$sandbox_home/.config" \
      ${networkFlags} \
      --chdir "$project_dir" \
      "''${entrypoint[@]}"
  '';
}
