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
  openssh,
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
      openssh
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

    # Per-project Chromium profile (isolates CDP port and session per sandbox)
    chromium_args=()
    chromium_profile="$project_dir/.config/chromium"
    mkdir -p "$chromium_profile"
    chromium_args+=(--bind "$chromium_profile" "$sandbox_home/.config/chromium")

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
      "''${chromium_args[@]}" \
      "''${git_args[@]}" \
      "''${gh_args[@]}" \
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
      --ro-bind-try /etc/locale.conf /etc/locale.conf \
      --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
      --ro-bind-try /etc/nix /etc/nix \
      --ro-bind-try /etc/static /etc/static \
      --dir /usr/bin \
      --ro-bind-try /usr/bin/env /usr/bin/env \
      "''${x11_args[@]}" \
      "''${xauth_args[@]}" \
      "''${wayland_args[@]}" \
      "''${dbus_args[@]}" \
      "''${audio_args[@]}" \
      "''${env_args[@]}" \
      --setenv HOME "$sandbox_home" \
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
