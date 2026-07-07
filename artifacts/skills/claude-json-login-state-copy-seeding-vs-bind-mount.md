# ~/.claude.json: login state lives here — seed by copy, never bind-mount

## The two auth files and what they actually hold

- `~/.claude/.credentials.json` — the OAuth **token**. Sharing `~/.claude`
  (directory bind / 9p) carries this fine; a directory bind source is stable.
- `~/.claude.json` — the `oauthAccount` record, onboarding/trust flags, and
  per-project state. **claude-code checks this at startup**: if it's missing
  or fresh, it runs the login/onboarding flow again *even though a valid
  token exists in `.credentials.json`*.

So "share `~/.claude`, drop `~/.claude.json`" ≠ "auth persists". We learned
this the hard way: commits `a4764aa`/`3b285ad` dropped `~/.claude.json` from
all backends (for good reasons, see below) and every new sandbox started
prompting for login.

## Why bind-mounting `~/.claude.json` is broken

claude-code rewrites the file via atomic rename (write temp, `rename(2)` over
the path). Two consequences:

1. **Launch race**: a bind mount resolves the source path at mount time; a
   concurrent host claude session swapping the inode makes bwrap abort with
   `Can't bind mount ... No such file or directory`.
2. **In-sandbox rewrites**: a single-file bind makes the in-sandbox path a
   mountpoint; `rename(2)` over a mountpoint fails (EBUSY), so the sandbox's
   own config writes are unreliable.

## The fix: copy at launch

A copy taken at launch never races (rename is atomic — a reader sees either
the complete old or complete new file), the in-sandbox file is a regular
file so renames over it work, and sandbox writes never leak to the host.
The cost: sandbox-side `.claude.json` changes are discarded per session —
acceptable, since the durable state (token, settings, permissions) lives in
the still-shared `~/.claude`.

Per-backend copy mechanism:

- **bubblewrap**: no writable pre-launch home exists (tmpfs HOME), so use
  bwrap's fd-content primitive:
  ```bash
  exec 11< "$HOME/.claude.json"           # fd pins a consistent snapshot
  args+=(--perms 0600 --file 11 "$sandbox_home/.claude.json")
  ```
  `--file FD DEST` writes the fd's contents as a regular file inside the
  sandbox. No temp files on the host, nothing to clean up.
- **container (nspawn)**: `cp` into the ephemeral container root before boot
  (`cp ... "$container_root$real_home/.claude.json"` + chown/chmod) — same
  pattern as the `.Xauthority` copy; a bind would be hidden by the
  `--ephemeral` overlay anyway.
- **VM (QEMU)**: `cp` into the 9p meta dir on the host; guest-side
  `interactiveShellInit` copies `/mnt/meta/claude.json` to
  `$host_home/.claude.json`.

## Verifying

Inside a sandbox shell (`claude-sandbox --shell <dir>`):

```bash
ls -la ~/.claude.json                      # regular 0600 file, user-owned
jq 'has("oauthAccount")' ~/.claude.json    # true → no login prompt
cp ~/.claude.json /tmp/x && mv /tmp/x ~/.claude.json  # rename works (not a mountpoint)
```
