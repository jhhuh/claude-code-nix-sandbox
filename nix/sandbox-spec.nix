# Sandbox specification — single source of truth for WHAT every sandbox needs.
# Each backend (bubblewrap, container, VM) implements HOW to deliver it.
#
# Programmatic fields (packages, chromeExtensionIds, hostEtcPaths) are consumed
# directly by backends. Complex mechanisms (dotfile mounts, sockets, env vars)
# stay as backend-specific code — see the documented checklist below.
{ pkgs }:
{
  # --- PROGRAMMATIC: consumed directly by backends ---

  # Core packages available inside every sandbox.
  # Chromium is intentionally excluded: bwrap uses chromiumSandbox wrapper,
  # container/VM use stock chromium. Each backend adds it separately.
  packages = with pkgs; [
    claude-code
    git
    gh
    openssh
    nodejs
    coreutils
    bash
    nix
  ];

  # Chrome extensions force-installed via managed policy.
  chromeExtensionIds = [
    "fcoeoabgfenejglbffodgkkbkcdhcgfn"  # Claude in Chrome
  ];

  # Host /etc paths forwarded into the sandbox (read-only).
  # Bubblewrap: --ro-bind-try per path
  # Container: for-loop --bind-ro per path
  # VM: N/A (own NixOS /etc)
  hostEtcPaths = [
    "/etc/resolv.conf"
    "/etc/hosts"
    "/etc/ssl"
    "/etc/ca-certificates"
    "/etc/pki"
    "/etc/fonts"
    "/etc/localtime"
    "/etc/zoneinfo"
    "/etc/locale.conf"
    "/etc/nix"
    "/etc/static"
    "/etc/nsswitch.conf"
  ];

  # Additional /etc paths only needed by bubblewrap.
  # Container and VM synthesize their own passwd/group/machine-id.
  hostEtcPathsBwrapOnly = [
    "/etc/passwd"
    "/etc/group"
    "/etc/machine-id"
  ];

  # --- DOCUMENTED CHECKLIST (backends implement explicitly) ---
  #
  # Dotfile mounts (mechanism differs per backend):
  #   ~/.claude, ~/.claude.json    — auth persistence (bind / 9p)
  #   ~/.gitconfig, ~/.config/git  — git config (ro-bind / 9p)
  #   ~/.ssh                       — SSH keys (ro-bind / 9p)
  #   ~/.config/gh                 — GitHub CLI config (ro-bind / 9p)
  #   .config/chromium             — per-project profile (bind / 9p)
  #
  # Sockets (mechanism differs per backend):
  #   X11 (/tmp/.X11-unix/Xn)     — display forwarding
  #   Xauthority                   — X11 auth cookie
  #   Wayland ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY)
  #   D-Bus system bus (/run/dbus/system_bus_socket) — NOT session bus
  #   PipeWire / PulseAudio        — audio
  #   Keyring (gnome-keyring)      — secrets
  #   SSH agent ($SSH_AUTH_SOCK)   — SSH key forwarding
  #   Nix daemon socket            — nix operations inside sandbox
  #
  # Environment variables (mechanism differs per backend):
  #   DISPLAY, WAYLAND_DISPLAY, XAUTHORITY — display
  #   HOME, TERM, PATH                     — shell basics
  #   CHROMIUM_USER_DATA_DIR               — per-project profile
  #   NIX_REMOTE=daemon                    — nix daemon
  #   XDG_RUNTIME_DIR, XDG_CONFIG_HOME     — XDG dirs
  #   SSH_AUTH_SOCK                         — SSH agent
  #   ANTHROPIC_API_KEY                     — API auth
  #   GH_TOKEN, GITHUB_TOKEN               — GitHub auth (opt-in --gh-token)
  #   LANG, LC_ALL                          — locale
  #
  # Directories created inside sandbox:
  #   /tmp, /run, /home, $HOME, $HOME/.config
  #   /bin (bash, sh), /usr/bin (bash, env)
  #   /etc/chromium/policies/managed/      — extension policy
  #
  # GPU forwarding:
  #   /dev/dri, /dev/shm, /run/opengl-driver
}
