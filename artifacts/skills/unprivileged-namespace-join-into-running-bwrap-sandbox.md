# Joining a running bubblewrap sandbox unprivileged (`--enter`)

How `claude-sandbox --enter` opens a shell inside a live sandbox's namespaces,
and the four things that make it fail if you get them wrong.

## It works, and needs no root

You own the user namespace bwrap created, so `setns(CLONE_NEWUSER)` succeeds,
and `setns(CLONE_NEWNS)` then succeeds too. Measured:

```
/tmp inside sandbox = []        (host /tmp had 9 entries)
host marker leaked? = False
mnt ns = mnt:[4026533266]       (host: mnt:[4026533254])
```

## The four gotchas

**1. Open every namespace fd BEFORE the first `setns`.** Joining the user
namespace changes your credentials; afterwards `/proc/<pid>/ns/*` lookups fail
with **ENOENT** (not EPERM, which is what makes it confusing). `nsenter(1)`
opens them all up front. A naive `setns(user); open(mnt); setns(mnt)` fails.

**2. `setns` does not move your root directory.** You keep a root dentry from
the old mount tree, so after joining, every path resolves ENOENT. You need
`fchdir` + `chroot` on a `/proc/<pid>/root` fd opened up front — that is what
`nsenter --root` does.

**3. Target the payload pid, not bwrap's `child-pid`.** bwrap's
`--json-status-fd` reports an *intermediate* process whose root is bwrap's
staging tree:

```
after fchdir(/proc/<child-pid>/root): ['newroot', 'oldroot']
```

Chrooting there lands you in the staging dir, not the sandbox. Fix used here:
the sandbox **registers itself from the inside**. There is no pid-namespace
unshare, so its pid is identical on both sides, and self-registration names
the payload process, whose `/proc/<pid>/root` is the real sandbox root.

**4. `--preserve-credentials` is mandatory.** bwrap writes `deny` to
`/proc/self/setgroups` when building its unprivileged uid_map, so nsenter's
default attempt to set uid/gid/groups fails:

```
nsenter: setgroups failed: Operation not permitted
```

## Environment is not inherited from the namespace

`nsenter` runs the command with **your** environment, not the sandbox's. A
joined shell would get the host `PATH` and `HOME` and none of the sandbox's
`--setenv` work. Replay the payload's own environment from `/proc`:

```bash
mapfile -d "" -t sandbox_env < "/proc/$live_pid/environ"
exec nsenter --target "$live_pid" --user --mount --root --preserve-credentials \
  --wd="$project_dir" \
  -- env -i "${sandbox_env[@]}" TERM="${TERM:-xterm-256color}" "${entrypoint[@]}"
```

`TERM` is reapplied last so it reflects the terminal doing the joining, not the
one that founded the sandbox.

## Registry: pid joins, inode validates

`setns` needs an open fd, so it needs a live process — pinning a namespace
without one requires a bind-mounted nsfs file and `CAP_SYS_ADMIN`, which is
unavailable unprivileged. So the registry stores both:

- **pid** — the join handle
- **ns inode** (`mnt:[4026533266]`) — the validity check

A bare pid is unsafe because pids recycle. Compare
`readlink /proc/<pid>/ns/mnt` against the recorded inode; mismatch or missing
pid means stale, so reap it. Verified against both failure modes: a pid that no
longer exists, and a pid recycled onto an unrelated process.

## Lifetime

`--die-with-parent` must be dropped once joining is possible, or closing the
terminal that founded the sandbox kills it under a shell joined from another
terminal. Orphans are reaped by the staleness check at launch, or via `--stop`.

## Never use `nsenter --wd` — it breaks getcwd(2), and thus every bun binary

This one cost hours and presented as a total red herring. `claude` failed in a
joined namespace with:

```
ENOENT: Bun could not find a file, and the code that produces this error is
missing a better error.
```

`git`, `python3`, `node` and `bun` itself all ran fine, so it looked specific
to bun **single-file executables**. Environment (diff was `SHLVL` alone),
uid/gid/groups, mnt namespace inode, `/proc/self/root` and `/proc/self/exe`
readability were all verified identical between founded and joined.

`strace` named it immediately — the tail of the trace is a `".."` walk:

```
openat(AT_FDCWD, "..", O_RDONLY) = 3
openat(3, "..", O_RDONLY) = 4
openat(4, "..", O_RDONLY) = 3
...
ENOENT: Bun could not find a file
```

That is a userspace `getcwd()` reimplementation climbing to the root. With
`--wd=<dir>`, nsenter leaves the cwd **unreachable from the chroot root it
installs**, so `getcwd(2)` fails ENOENT — while `/proc/self/cwd` still
resolves correctly, which is what makes it so confusing:

```
python3 -c 'import os; os.getcwd()'  -> FileNotFoundError
readlink /proc/self/cwd              -> /home/jhhuh/Sync/proj/...   (fine)
```

**Do not verify cwd with `pwd` in bash** — bash prints `$PWD` from the
environment and never calls `getcwd`, so it reports success while the syscall
is broken. That false signal is why the cause was missed for so long.

Fix: drop `--wd` and `cd` after entry, so the path resolves against the new
root and the cwd is reachable:

```bash
bash -c 'cd "$1" || exit 1; shift; exec "$@"' bash "$project_dir" "${entrypoint[@]}"
```

With that, claude runs joined and singleton-by-default works.

## `--new` must not register

An explicitly isolated sandbox must skip self-registration. Otherwise it
overwrites the registry, hijacking the singleton slot from the sandbox already
running for that project — which then becomes undiscoverable as soon as the
`--new` one exits.

## Debugging note

`os._exit()` skips stdout flushing, so a failing branch can print nothing and
look like a silent crash. Write diagnostics with `os.write(2, ...)` when
testing setns in forked children, or you will misread the failure.
