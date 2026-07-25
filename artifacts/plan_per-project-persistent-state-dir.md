# Plan: per-project state dir + singleton namespace

Supersedes the earlier revision of this file (per-project state dir only).
The singleton decision changes what the socket exposure is *for*.

## Problems

**1. Backends write sandbox state into the user's project directory:**

| what | where | backend |
|---|---|---|
| tmux.conf + socket | `$project_dir/.tmux/` | bubblewrap |
| chromium profile | `$project_dir/.config/chromium/` | bubblewrap, container |
| machine name | `$project_dir/.config/claude-sandbox-machine` | container |

Untracked junk in every repo the sandbox touches; `.tmux/tmux.conf` gets
committed by accident; a committed chromium profile would leak cookies and
browsing state. Nothing is tracked in *this* repo (`git log --all -- .tmux
.config` is empty) — the incident was in another project.

**2. No way to inspect a running sandbox.** Every invocation creates a fresh
namespace, so there is no way to open a shell in a live session's mount
namespace and see what the agent actually did to `/tmp`, `$HOME`, etc.

## Layout

```
${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-nix-sandbox/
  CACHEDIR.TAG                       # direnv precedent (stdlib.sh:783)
  projects/<basename>-<sha256(path+"\n")[:12]>/
    path                             # full project path, plaintext
    chromium/                        # CHROMIUM_USER_DATA_DIR
    tmux.conf                        # persists, user-editable
    tmux.sock                        # host-visible: attach to the live claude UI
    machine                          # container machine name
    ns                               # registry: pid + mnt/user ns inodes + started
```

Bound into the sandbox at its real host path, like `project_dir`.

## Singleton semantics

Default becomes **one sandbox per project**. First invocation founds the
namespace and records `ns`; later invocations join it via `setns`.

- `--new` forces a fresh, isolated namespace (does not touch the registry).
- `--enter` joins an existing sandbox, erroring if none is live.
- `--stop` tears down the project's sandbox.
- Joining always prints a notice naming the pid and start time. Never silent.

### Evidence it works (measured, nested inside a sandbox)

An unprivileged process CAN join a running bwrap sandbox:

```
/tmp inside sandbox = []        (host /tmp had 9 entries)
host marker leaked? = False
mnt ns = mnt:[4026533266]       (host: mnt:[4026533254])
```

`setns(CLONE_NEWUSER)` succeeds because we own the user namespace bwrap
created; `setns(CLONE_NEWNS)` then succeeds. Three gotchas, all real:

1. **Open every ns fd BEFORE the first `setns`.** After joining the user
   namespace, credentials change and `/proc/<pid>/ns/*` lookups fail ENOENT.
2. **`setns` does not move the root directory.** Without `fchdir`+`chroot` on
   an fd opened up-front, every path resolves ENOENT. (`nsenter --root`.)
3. **bwrap's `--json-status-fd` `child-pid` is the intermediate process**,
   whose root is bwrap's staging tree (`newroot`/`oldroot`), not the sandbox
   root. Descend into `newroot`, or target the payload pid.

`nsenter(1)` handles all three -> ship `util-linux` (also gets `lsns`,
`findmnt`, both currently missing).

### Registry and staleness

`setns` needs an open fd, so it needs a live process: pinning a namespace
without one requires a bind-mounted nsfs file and CAP_SYS_ADMIN, which we do
not have unprivileged. Therefore:

- **pid** = the join handle
- **ns inode** (`mnt:[4026533266]`) = the validity check

PIDs recycle, so a bare pid is unsafe. Compare `readlink /proc/<pid>/ns/mnt`
against the recorded inode; mismatch or missing pid => stale, reap it.

### Lifetime

`--die-with-parent` (`bubblewrap.nix:280`) is wrong under a singleton: closing
the founding terminal would tear the ground out from under a joined shell.
Chosen: **drop it, reap explicitly.** `--stop` for explicit teardown, plus
opportunistic reaping at launch when the registry has no live members. Orphans
self-heal on next use rather than needing a daemon.

### Why singleton-by-default is safe here

Measured across the user's own session history: 19 sessions parsed, **2
same-project overlapping pairs**, both in the pseudo-project `-home-jhhuh`,
both <=2 minutes — session handoffs, not parallel work. The 34% multi-clauding
figure in the usage report counts overlap across *different* projects.

The main future source of same-project concurrency is the inspect-shell
itself, and there sharing is the objective, not a hazard.

## Non-constraint (recorded so it is not re-derived)

An earlier revision truncated directory names to fit `sun_path` (108 bytes),
assuming chromium binds `<profile>/SingletonSocket`. **It does not.** Per
`process_singleton_posix.cc`, the socket is bound in a unique temp dir
(`:1042`, `:1056`, `:1060`); `<profile>/SingletonSocket` is only a symlink to
it (`:765`, `:1068`), and the comment at `:1054` says this exists precisely to
avoid long-path failures. Profile path length is irrelevant; no truncation.

This contradicts `artifacts/skills/chromium-cross-sandbox-isolation-dbus-and-cdp.md:22-26`,
which claims chromium uses abstract sockets keyed on the profile path string.
That file is referenced from CLAUDE.md and must be corrected. Its D-Bus half
(root cause 1, `env -u DBUS_SESSION_BUS_ADDRESS`) is well-supported and was
likely doing the real work.

## Steps

Two commits.

**A. State relocation** (no behavior change beyond where files live)
1. `sandbox-spec.nix`: ship `util-linux`; add state-root/mangling helpers.
2. `bubblewrap.nix`: resolve state dir, bind at real path, move chromium
   profile + tmux config/socket, write `path` + `CACHEDIR.TAG`.
3. `container.nix`: same, plus `machine`.
4. `vm.nix`: chromium profile + tmux.conf via the existing 9p meta share.
   -> verify: `nix build .#sandbox .#container`; vm parse-only (still blocked
   on the pre-existing `virtualisation.vlans` regression).

**B. Singleton namespace**
5. Registry write on found; join path via `nsenter`; `--enter`, `--new`,
   `--stop`; drop `--die-with-parent`; reap stale at launch.
6. Container: prefer `machinectl shell <machine>` over nsenter — nspawn
   supports it natively and the backend already assigns a machine name.
   VM: not a namespace; keeps the serial console. Document, do not fake it.
   -> verify: second invocation reports the same mnt ns inode; `--new` gives a
   different one; a forged stale pid is detected; `--stop` tears down.

**C. Docs**
7. Correct the chromium skill file; add a skill file for unprivileged
   namespace joining; update CLAUDE.md.

## Open / deferred

- Concurrent same-project chromium under `--new`: the profile persists per
  project so two isolated sandboxes still share it. Taking **ephemeral
  fallback** for the second (throwaway profile + notice) over refusing.
  Failure mode is likely profile corruption, not session stealing, since each
  sandbox has its own /tmp so the SingletonSocket symlink target does not
  resolve across sandboxes — inferred, not tested.
- The per-project tmux socket collision is *relocated* by commit A and only
  *fixed* by commit B's singleton semantics. Flag in commit A's message.
- No migration of existing `.tmux/` / `.config/chromium/`: moving a live
  browser profile is risky. Ship a cleanup one-liner instead.
