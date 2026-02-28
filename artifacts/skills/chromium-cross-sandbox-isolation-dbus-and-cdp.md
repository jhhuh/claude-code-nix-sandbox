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

### 2. Abstract socket collision on shared network namespace

Chromium uses abstract Unix sockets (which live in the network namespace, not the filesystem) for IPC. The socket name is derived from the **profile path string**. If two sandboxes both mount different storage to the same in-sandbox path (`~/.config/chromium`), the path strings are identical → same abstract socket → collision.

**Fix**: The `chromiumSandbox` package (nix/chromium.nix) reads `CHROMIUM_USER_DATA_DIR` env var and passes `--user-data-dir` to the real binary. Each backend sets this env var to `$project_dir/.config/chromium`, giving each project a globally unique abstract socket name.

```bash
# Backend sets the env var:
--setenv CHROMIUM_USER_DATA_DIR "$chromium_profile"
# chromiumSandbox wrapper handles the rest:
exec chromium --user-data-dir=$CHROMIUM_USER_DATA_DIR "$@"
```

This replaced the previous approach of generating runtime wrapper scripts at `<project-dir>/.config/chromium-wrapper/` — the Nix package handles it now.

## Why not `--unshare-net`?

Isolating the network namespace would fix socket conflicts but breaks internet access (needed for Claude Code API calls, `git push`, `npm install`, etc.). The wrapper approach solves the problem without sacrificing connectivity.

## Why not bind-mount to a common in-sandbox path?

Mounting `<project-dir>/.config/chromium` to `~/.config/chromium` inside each sandbox means the in-sandbox path string is identical across sandboxes. Since abstract sockets are keyed on path strings and live in the shared network namespace, they still collide. The `--user-data-dir` flag with the **real host path** is the key — each project gets a globally unique socket name.

## Verified

Tested with two concurrent bubblewrap sandboxes:
- Both chromium instances started successfully on different random CDP ports (41899, 35605)
- Each created independent `SingletonLock` files in their project dirs
- No session stealing observed
