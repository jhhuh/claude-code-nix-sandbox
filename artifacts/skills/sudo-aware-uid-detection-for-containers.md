# Sudo-aware UID detection for containers

## Problem

When a container launcher runs under `sudo`, `$USER` is `root` and `$HOME` is `/root`. Files created inside the container with a hardcoded UID (e.g., 1000) won't match the real user's UID, causing permission mismatches on bind-mounted directories.

## Solution

Detect the real user's identity from `SUDO_USER`, falling back to current user when not under sudo:

```bash
real_user="${SUDO_USER:-${USER}}"
real_uid="$(id -u "$real_user")"
real_gid="$(id -g "$real_user")"
real_home="$(getent passwd "$real_user" | cut -d: -f6)"
```

**`SUDO_HOME` does not exist.** Sudo only sets `SUDO_USER`, `SUDO_UID`, `SUDO_GID`, `SUDO_COMMAND`. Never use `${SUDO_HOME:-${HOME}}` — under `env_reset`, `HOME=/root`, so it silently resolves to root's home. Always derive home from the passwd database via `getent passwd`.

Use these throughout the script instead of hardcoded values:
- Container `/etc/passwd` and `/etc/group` entries
- `setpriv --reuid=$real_uid --regid=$real_gid`
- `chown $real_uid:$real_gid`
- XDG runtime dir paths (`/run/user/$real_uid/`)

## ShellCheck caveat

When using `$real_uid` inside bash array assignments, always quote the entire string:

```bash
# Wrong — SC2206 warning
args+=(--setenv=XDG_RUNTIME_DIR=/run/user/$real_uid)

# Correct
args+=("--setenv=XDG_RUNTIME_DIR=/run/user/$real_uid")
```

`writeShellApplication` in Nix treats ShellCheck warnings as errors.

## Bubblewrap note

Bubblewrap (`bwrap`) doesn't need this — it runs unprivileged and inherits the host user's UID naturally. Only needed for privileged launchers like `systemd-nspawn`.
