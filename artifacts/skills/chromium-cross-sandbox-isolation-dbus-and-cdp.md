# Chromium cross-sandbox isolation: D-Bus singleton and CDP port

## Problem

Two bubblewrap/nspawn sandboxes on the same host run separate Chromium instances, but the second sandbox's Chrome "steals" the first's session — opening tabs in the wrong sandbox or failing to start.

## Root causes

### 1. D-Bus session bus singleton

Chromium registers `org.chromium.Chromium` on the D-Bus session bus. When the second sandbox starts Chrome, it finds the first's registration via the shared session bus and forwards its window request there instead of starting a new instance.

**Fix**: The `chromiumSandbox` wrapper (nix/chromium.nix) strips `DBUS_SESSION_BUS_ADDRESS` from Chromium's environment via `env -u DBUS_SESSION_BUS_ADDRESS`. The session bus is forwarded into the sandbox (so other tools like `gh` can access gnome-keyring via the Secret Service API), but Chromium can't see it and therefore can't register its singleton.

```bash
# chromium.nix wrapper:
exec env -u DBUS_SESSION_BUS_ADDRESS chromium --user-data-dir=$CHROMIUM_USER_DATA_DIR "$@"
```

This replaced the previous approach of dropping the session bus entirely, which broke `gh auth status` (gh stores OAuth tokens in gnome-keyring via D-Bus Secret Service API).

### 2. Abstract socket collision on shared network namespace

Chromium uses abstract Unix sockets (which live in the network namespace, not the filesystem) for IPC. The socket name is derived from the **profile path string**. If two sandboxes both mount different storage to the same in-sandbox path (`~/.config/chromium`), the path strings are identical → same abstract socket → collision.

**Fix**: The `chromiumSandbox` package (nix/chromium.nix) reads `CHROMIUM_USER_DATA_DIR` env var and passes `--user-data-dir` to the real binary. Each backend sets this env var to `$project_dir/.config/chromium`, giving each project a globally unique abstract socket name.

```bash
# Backend sets the env var:
--setenv CHROMIUM_USER_DATA_DIR "$chromium_profile"
```

## Session bus forwarding details

Backends parse `DBUS_SESSION_BUS_ADDRESS` and bind-mount the socket:
- **bubblewrap**: `--ro-bind $socket $socket` (same path, shared network namespace)
- **container**: `--bind-ro=$socket:/run/user/$uid/bus` (remapped to container runtime dir)
- **VM**: Not applicable — VM has its own D-Bus inside the NixOS guest

For `unix:path=...` addresses, the socket file is bind-mounted. Abstract sockets (`unix:abstract=...`) work without bind-mount in bubblewrap since it shares the host network namespace.

## Why not `--unshare-net`?

Isolating the network namespace would fix socket conflicts but breaks internet access (needed for Claude Code API calls, `git push`, `npm install`, etc.). The wrapper approach solves the problem without sacrificing connectivity.

## Why not bind-mount to a common in-sandbox path?

Mounting `<project-dir>/.config/chromium` to `~/.config/chromium` inside each sandbox means the in-sandbox path string is identical across sandboxes. Since abstract sockets are keyed on path strings and live in the shared network namespace, they still collide. The `--user-data-dir` flag with the **real host path** is the key — each project gets a globally unique socket name.

## Why not xdg-dbus-proxy?

Considered using `xdg-dbus-proxy` to create a per-sandbox filtered proxy allowing only `org.freedesktop.secrets`. Rejected because it requires running a separate daemon process on the host for each sandbox session. The `env -u` approach in the wrapper is simpler (no extra process, no cleanup).

## Verified

Tested with two concurrent bubblewrap sandboxes:
- Both chromium instances started successfully on different random CDP ports (41899, 35605)
- Each created independent `SingletonLock` files in their project dirs
- No session stealing observed
