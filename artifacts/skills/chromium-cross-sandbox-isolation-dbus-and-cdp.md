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

### 2. Profile sharing on a shared network namespace

> **CORRECTED 2026-07-25.** This section previously claimed chromium uses
> *abstract* Unix sockets whose name derives from the profile path string, and
> that claim drove a whole design round (budgeting directory names against the
> 108-byte `sun_path` limit). It is wrong. From
> `chrome/browser/process_singleton_posix.cc`:
>
> ```
> 1042:  if (!socket_dir_.CreateUniqueTempDir(...))
> 1056:  socket_target_path = socket_dir_.GetPath().Append(kSingletonSocketFilename);
> 1060:  SetupSocket(socket_target_path.value(), &sock_, &addr, &socklen);
> 1068:  if (!SymlinkPath(socket_target_path, socket_path_) || ...
>  765:  socket_path_ = user_data_dir.Append(chrome::kSingletonSocketFilename);
> ```
>
> The socket is bound in a **unique temp dir**; `<profile>/SingletonSocket` is
> only a **symlink** to it. The comment at `:1054` says this exists precisely
> to avoid long-path failures. **Profile path length is therefore irrelevant**,
> and no name truncation is needed anywhere.
>
> What remains true: give each project its own profile directory. Not because
> of socket naming, but because a profile is per-project state (cookies,
> history, logins) and two projects sharing one would be wrong on its own
> terms. Root cause 1 (D-Bus) is well-supported and was likely doing the real
> isolation work all along.

Each project gets its own `--user-data-dir`, so two sandboxes never operate on the same profile directory.

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

Each project keeps a distinct profile path, bound at its real host path. Note
the original justification here — that a shared in-sandbox path would collide
on abstract sockets — was **wrong**, see the correction in root cause 2. The
practical reason stands: distinct directories keep per-project browser state
(cookies, logins, history) from bleeding between projects.

Profiles now live in the per-project state dir
(`${XDG_STATE_HOME:-~/.local/state}/claude-code-nix-sandbox/projects/<name>-<hash>/chromium`),
not in the project directory, so a browser profile is never committed to a repo.

## Why not xdg-dbus-proxy?

Considered using `xdg-dbus-proxy` to create a per-sandbox filtered proxy allowing only `org.freedesktop.secrets`. Rejected because it requires running a separate daemon process on the host for each sandbox session. The `env -u` approach in the wrapper is simpler (no extra process, no cleanup).

## Verified

Tested with two concurrent bubblewrap sandboxes:
- Both chromium instances started successfully on different random CDP ports (41899, 35605)
- Each created independent `SingletonLock` files in their project dirs
- No session stealing observed
