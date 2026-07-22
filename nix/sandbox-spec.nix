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
    bun  # some claude-code plugin hooks use #!/usr/bin/env bun
    python3  # claude-code's security-guidance SessionStart hook needs a Python 3 interpreter
    tmux
    coreutils
    bash
    nix
    xclip  # claude-code's /copy shells out to a clipboard binary; reaches the
           # host X CLIPBOARD via the forwarded DISPLAY/X socket/Xauthority
  ];

  # Chrome extensions force-installed via managed policy.
  chromeExtensionIds = [
    "fcoeoabgfenejglbffodgkkbkcdhcgfn"  # Claude in Chrome
  ];

  # Notice appended to every sandboxed claude session's system prompt
  # (via `claude --append-system-prompt`) so the agent knows it is sandboxed
  # and must not treat sandbox-local observations as facts about the host.
  # `backend` is the backend name (bubblewrap / container / vm).
  sandboxNotice = backend:
    "You are running inside an isolated ${backend} sandbox created by " +
    "claude-code-nix-sandbox. The host machine's filesystem, PATH, " +
    "environment, and installed tools are NOT visible from inside this " +
    "sandbox: any command you run here (command -v, ls, env, package or " +
    "tool checks) reflects only the sandbox, never the host. Do not infer " +
    "host state from commands run here; if you need a fact about the host, " +
    "ask the user. Only the current project directory and explicitly " +
    "forwarded dotfiles are shared with the host.";

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
  #   ~/.claude                    — auth persistence (bind / 9p); login token in
  #                                  .credentials.json, permissions in settings.json
  #   ~/.claude.json               — seeded by COPY at launch, never bind-mounted
  #                                  (claude-code rewrites it via atomic rename, so a
  #                                  live bind races with a host session). It carries
  #                                  the oauthAccount/onboarding state — without the
  #                                  seed every sandbox prompts for login. Sandbox
  #                                  writes stay local, never touch the host file.
  #   ~/.gitconfig, ~/.config/git  — git config (ro-bind / 9p)
  #   ~/.ssh                       — SSH keys (ro-bind / 9p)
  #   ~/.config/gh                 — GitHub CLI config (ro-bind / 9p)
  #   .config/chromium             — per-project profile (bind / 9p)
  #
  # Sockets (mechanism differs per backend):
  #   X11 (/tmp/.X11-unix/Xn)     — display forwarding
  #   Xauthority                   — X11 auth cookie
  #   Wayland ($XDG_RUNTIME_DIR/$WAYLAND_DISPLAY)
  #   D-Bus system bus (/run/dbus/system_bus_socket) — direct bind
  #   D-Bus session bus — forwarded for Secret Service API (keyring);
  #     Chromium isolated via env -u DBUS_SESSION_BUS_ADDRESS in wrapper
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
