# Bubblewrap sandbox backend for Claude Code + Chromium
#
# Usage: claude-sandbox [--shell] [--gh-token] <project-dir> [claude args...]
#
# Produces a writeShellApplication that wraps bwrap to isolate
# claude-code and chromium with access to a single project directory.
# Automatically bind-mounts ~/.claude for auth persistence if it exists.
{
  lib,
  pkgs,
  writeShellApplication,
  symlinkJoin,
  bubblewrap,
  chromiumSandbox,
  coreutils,
  # Toggle host network access (set false to --unshare-net)
  network ? true,
  # Additional packages available inside the sandbox
  extraPackages ? [ ],
}:

let
  spec = import ../sandbox-spec.nix { inherit pkgs; };

  sandboxPath = symlinkJoin {
    name = "claude-sandbox-path";
    paths = spec.packages ++ [ chromiumSandbox ] ++ extraPackages;
  };

  networkFlags = lib.optionalString (!network) "--unshare-net";
in
writeShellApplication {
  name = "claude-sandbox";
  runtimeInputs = [ bubblewrap coreutils ];

  text = ''
    shell_mode=false
    gh_token=false
    while [[ "''${1:-}" == --* ]]; do
      case "''${1:-}" in
        --shell) shell_mode=true; shift ;;
        --gh-token) gh_token=true; shift ;;
        --help|-h) break ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    if [[ $# -lt 1 ]] || [[ "''${1:-}" == "--help" ]] || [[ "''${1:-}" == "-h" ]]; then
      echo "Usage: claude-sandbox [--shell] [--gh-token] <project-dir> [claude args...]" >&2
      echo "  --shell     Drop into bash instead of launching claude" >&2
      echo "  --gh-token  Forward GH_TOKEN/GITHUB_TOKEN env vars into sandbox" >&2
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

    # D-Bus forwarding — only the system bus.
    # Session bus is intentionally NOT forwarded: sharing it lets Chromium
    # instances across sandboxes discover each other via org.chromium.Chromium,
    # causing the second sandbox's Chrome to hijack the first's session.
    dbus_args=()
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

    # Audio forwarding (PipeWire and PulseAudio)
    audio_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      # PipeWire
      if [[ -e "$XDG_RUNTIME_DIR/pipewire-0" ]]; then
        audio_args+=(--ro-bind "$XDG_RUNTIME_DIR/pipewire-0" "$XDG_RUNTIME_DIR/pipewire-0")
      fi
      # PulseAudio
      if [[ -e "$XDG_RUNTIME_DIR/pulse/native" ]]; then
        audio_args+=(--ro-bind "$XDG_RUNTIME_DIR/pulse" "$XDG_RUNTIME_DIR/pulse")
      fi
    fi

    # Keyring socket forwarding (gnome-keyring, KDE wallet)
    keyring_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]] && [[ -d "$XDG_RUNTIME_DIR/keyring" ]]; then
      keyring_args+=(--ro-bind "$XDG_RUNTIME_DIR/keyring" "$XDG_RUNTIME_DIR/keyring")
    fi

    # Determine sandbox home directory
    sandbox_home="$HOME"

    # Prepare XDG_RUNTIME_DIR bind args (needs --dir before bind since /run is tmpfs)
    xdg_runtime_args=()
    if [[ -n "''${XDG_RUNTIME_DIR:-}" ]]; then
      xdg_runtime_args+=(--dir "$XDG_RUNTIME_DIR")
    fi

    # Claude auth and config persistence
    claude_auth_args=()
    host_claude_dir="''${HOME}/.claude"
    mkdir -p "$host_claude_dir"
    claude_auth_args+=(--bind "$host_claude_dir" "$sandbox_home/.claude")
    if [[ -f "''${HOME}/.claude.json" ]]; then
      claude_auth_args+=(--bind "''${HOME}/.claude.json" "$sandbox_home/.claude.json")
    fi

    # Per-project Chromium profile with unique user-data-dir path.
    # Chromium derives abstract socket names from the profile path. Since all
    # sandboxes share the host network namespace, mounting different storage to
    # the same in-sandbox path (~/.config/chromium) still collides. Using the
    # project's real path as --user-data-dir gives each sandbox a unique socket.
    chromium_profile="$project_dir/.config/chromium"
    mkdir -p "$chromium_profile"

    # Git and SSH forwarding (read-only)
    git_args=()
    if [[ -f "$HOME/.gitconfig" ]]; then
      git_args+=(--ro-bind "$HOME/.gitconfig" "$sandbox_home/.gitconfig")
    fi
    if [[ -d "$HOME/.config/git" ]]; then
      git_args+=(--dir "$sandbox_home/.config/git")
      git_args+=(--ro-bind "$HOME/.config/git" "$sandbox_home/.config/git")
    fi
    if [[ -d "$HOME/.ssh" ]]; then
      git_args+=(--ro-bind "$HOME/.ssh" "$sandbox_home/.ssh")
    fi
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]] && [[ -e "$SSH_AUTH_SOCK" ]]; then
      git_args+=(--ro-bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
    fi

    # GitHub CLI config (always mounted, like gitconfig)
    gh_args=()
    if [[ -d "''${HOME}/.config/gh" ]]; then
      gh_args+=(--dir "$sandbox_home/.config/gh")
      gh_args+=(--ro-bind "''${HOME}/.config/gh" "$sandbox_home/.config/gh")
    fi

    # Conditional env vars (only set when non-empty on host)
    env_args=()
    if [[ -n "''${DISPLAY:-}" ]]; then
      env_args+=(--setenv DISPLAY "$DISPLAY")
    fi
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
      env_args+=(--setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY")
    fi
    if [[ -n "''${XAUTHORITY:-}" ]]; then
      env_args+=(--setenv XAUTHORITY "$XAUTHORITY")
    fi
    # DBUS_SESSION_BUS_ADDRESS intentionally not forwarded (see D-Bus comment above)
    if [[ "$gh_token" == true ]]; then
      if [[ -n "''${GH_TOKEN:-}" ]]; then
        env_args+=(--setenv GH_TOKEN "$GH_TOKEN")
      fi
      if [[ -n "''${GITHUB_TOKEN:-}" ]]; then
        env_args+=(--setenv GITHUB_TOKEN "$GITHUB_TOKEN")
      fi
    fi
    if [[ -n "''${ANTHROPIC_API_KEY:-}" ]]; then
      env_args+=(--setenv ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY")
    fi
    if [[ -n "''${SSH_AUTH_SOCK:-}" ]]; then
      env_args+=(--setenv SSH_AUTH_SOCK "$SSH_AUTH_SOCK")
    fi
    if [[ -n "''${LANG:-}" ]]; then
      env_args+=(--setenv LANG "$LANG")
    fi
    if [[ -n "''${LC_ALL:-}" ]]; then
      env_args+=(--setenv LC_ALL "$LC_ALL")
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
      "''${git_args[@]}" \
      "''${gh_args[@]}" \
      --bind "$project_dir" "$project_dir" \
      ${lib.concatMapStringsSep " \\\n  " (p: "--ro-bind-try ${p} ${p}") (spec.hostEtcPaths ++ spec.hostEtcPathsBwrapOnly)} \
      --dir /etc/chromium \
      --dir /etc/chromium/policies \
      --dir /etc/chromium/policies/managed \
      --ro-bind ${chromiumSandbox.extensionPolicy} /etc/chromium/policies/managed/default.json \
      --dir /bin \
      --symlink "${sandboxPath}/bin/bash" /bin/bash \
      --symlink "${sandboxPath}/bin/bash" /bin/sh \
      --dir /usr/bin \
      --symlink "${sandboxPath}/bin/bash" /usr/bin/bash \
      --ro-bind-try /usr/bin/env /usr/bin/env \
      "''${x11_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      "''${audio_args[@]}" \
      "''${keyring_args[@]}" \
      "''${env_args[@]}" \
      --setenv HOME "$sandbox_home" \
      --setenv CHROMIUM_USER_DATA_DIR "$chromium_profile" \
      --setenv PATH "${sandboxPath}/bin" \
      --setenv TERM "''${TERM:-xterm-256color}" \
      --setenv NIX_REMOTE daemon \
      --setenv XDG_RUNTIME_DIR "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
      --setenv XDG_CONFIG_HOME "$sandbox_home/.config" \
      ${networkFlags} \
      --chdir "$project_dir" \
      "''${entrypoint[@]}"
  '';
}
