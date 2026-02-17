# Forwarding nix-daemon into sandboxes (bwrap / nspawn)

## Problem

You want `nix` commands (eval, build, etc.) to work inside a sandboxed environment that shares the host's `/nix/store`. The nix CLI needs access to the nix daemon to query and build packages.

## Solution: three requirements

### 1. Bind-mount the daemon socket (read-write)

The daemon socket at `/nix/var/nix/daemon-socket/socket` is a Unix socket that requires read-write access. A read-only bind will fail with `Permission denied`.

**Bubblewrap:**
```bash
--bind-try /nix/var/nix/daemon-socket /nix/var/nix/daemon-socket
```

**systemd-nspawn:**
```bash
--bind=/nix/var/nix/daemon-socket
```

Also bind the store database read-only:
```bash
--ro-bind-try /nix/var/nix/db /nix/var/nix/db  # bwrap
--bind-ro=/nix/var/nix/db                        # nspawn
```

### 2. Set `NIX_REMOTE=daemon`

Without this, the nix CLI tries to access the store database directly (opening `/nix/var/nix/db/big-lock`), which fails because the db is read-only. Setting `NIX_REMOTE=daemon` forces it to go through the daemon socket.

```bash
--setenv NIX_REMOTE daemon
```

### 3. Include `nix` in the sandbox PATH

Add the `nix` package to whatever mechanism builds the sandbox's PATH (`symlinkJoin` for bwrap, `environment.systemPackages` for nspawn/VM).

## Verification

Inside the sandbox:
```bash
nix eval nixpkgs#hello.name
# Expected: "hello-2.12.1"
```

## Gotcha: ro-bind for unix sockets

Unix domain sockets require the connecting process to have write permission on the socket file. A read-only bind-mount strips write permission, causing `connect()` to fail with EACCES. Always use read-write binds for sockets you need to connect to.
