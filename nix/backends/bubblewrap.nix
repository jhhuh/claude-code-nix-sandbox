# Bubblewrap sandbox backend for Claude Code + Chromium
#
# Usage: claude-sandbox <project-dir> [claude args...]
#
# Produces a writeShellApplication that wraps bwrap to isolate
# claude-code and chromium with access to a single project directory.
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
    ] ++ extraPackages;
  };

  networkFlags = lib.optionalString (!network) "--unshare-net";
in
writeShellApplication {
  name = "claude-sandbox";
  runtimeInputs = [ bubblewrap coreutils ];

  text = ''
    if [[ $# -lt 1 ]]; then
      echo "Usage: claude-sandbox <project-dir> [claude args...]" >&2
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

    # DRI (GPU) forwarding for Chromium hardware acceleration
    dri_args=()
    if [[ -d /dev/dri ]]; then
      dri_args+=(--dev-bind /dev/dri /dev/dri)
    fi

    # Determine sandbox home directory
    sandbox_home="/home/sandbox"

    exec bwrap \
      --die-with-parent \
      --proc /proc \
      --dev /dev \
      --dev-bind /dev/shm /dev/shm \
      "''${dri_args[@]}" \
      --ro-bind /nix/store /nix/store \
      --ro-bind /run/current-system/sw /run/current-system/sw \
      --tmpfs /tmp \
      --tmpfs /run \
      --tmpfs /home \
      --dir "$sandbox_home" \
      --dir "$sandbox_home/.config" \
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
      --setenv XDG_RUNTIME_DIR "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
      --setenv XDG_CONFIG_HOME "$sandbox_home/.config" \
      ${networkFlags} \
      --chdir "$project_dir" \
      claude "$@"
  '';
}
