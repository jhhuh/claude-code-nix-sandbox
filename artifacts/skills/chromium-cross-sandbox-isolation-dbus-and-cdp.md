# Chromium cross-sandbox isolation: D-Bus singleton and CDP port

## Problem

Two bubblewrap/nspawn sandboxes on the same host run separate Chromium instances, but the second sandbox's Chrome "steals" the first's session — opening tabs in the wrong sandbox or failing to start.

## Root causes

### 1. D-Bus session bus singleton

Chromium registers `org.chromium.Chromium` on the D-Bus session bus. When the second sandbox starts Chrome, it finds the first's registration via the shared session bus and forwards its window request there instead of starting a new instance.

**Fix**: Don't forward the host's D-Bus session bus into sandboxes. Keep the system bus (for NetworkManager, DNS, etc.) but drop the session bus entirely. Chromium works without it — just loses desktop integration (notifications, portal file dialogs).

```bash
# Only system bus, no session bus
dbus_args=()
if [[ -S /run/dbus/system_bus_socket ]]; then
  dbus_args+=(--ro-bind /run/dbus/system_bus_socket /run/dbus/system_bus_socket)
fi
# Do NOT forward DBUS_SESSION_BUS_ADDRESS
```

### 2. CDP port on shared network namespace

Chrome DevTools Protocol (CDP) uses a TCP port (default 9222). Both sandboxes share the host's network namespace (`--unshare-net` is off for internet access), so the second Chromium can't bind the same port, or connects to the first's debugger.

**Fix**: Use per-project Chromium profiles. Each sandbox mounts `<project-dir>/.config/chromium/` as `~/.config/chromium` inside the sandbox. Different profile paths = different CDP sockets and SingletonLock files.

```bash
chromium_profile="$project_dir/.config/chromium"
mkdir -p "$chromium_profile"
# bwrap: --bind "$chromium_profile" "$sandbox_home/.config/chromium"
# nspawn: --bind="$chromium_profile":"$real_home/.config/chromium"
```

## Why not `--unshare-net`?

Isolating the network namespace would fix CDP conflicts but breaks internet access (needed for Claude Code API calls, `git push`, `npm install`, etc.). The per-project profile approach solves the problem without sacrificing connectivity.

## Why not bind-mount the host's `~/.config/chromium`?

Sharing the host profile between sandboxes causes the same CDP/singleton conflicts. Even between a sandbox and the host browser. Per-project profiles are the cleanest isolation boundary.
