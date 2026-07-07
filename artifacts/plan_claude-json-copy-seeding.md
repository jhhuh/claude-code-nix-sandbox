# Plan: seed ~/.claude.json by copy so sandboxes stay logged in

## Problem

Commits `a4764aa` / `3b285ad` stopped sharing `~/.claude.json` with sandboxes
(bind-mounting the live file raced with host claude-code's atomic-rename
rewrites and aborted launches). But `~/.claude.json` holds the `oauthAccount`
and onboarding record — without it, claude-code prompts for login on every
sandbox creation even though the OAuth token in `~/.claude/.credentials.json`
is still shared.

## Fix

Seed each sandbox with a **copy** of the host's `~/.claude.json` at launch.
A copy taken at launch is immune to the atomic-rename race (rename is atomic;
a read sees either the old or new complete file), the in-sandbox file is a
regular file so claude-code's own rename-rewrite works, and sandbox writes
still never touch host state.

Per backend:

1. `nix/backends/bubblewrap.nix` → verify: `nix build .#sandbox`
   - Open host file on fd 11 (`exec 11<`, pins a consistent snapshot), pass
     `--perms 0600 --file 11 $sandbox_home/.claude.json` to bwrap, which
     writes the fd contents as a regular file in the tmpfs home.
2. `nix/backends/container.nix` → verify: `nix build .#container`
   - `cp` into the ephemeral container root + chown, same pattern as the
     existing `.Xauthority` copy (bind of a file would be hidden by
     `--ephemeral` overlay anyway).
3. `nix/backends/vm.nix` → verify: `nix build .#vm` (was broken by unrelated
   nixpkgs regression at 3b285ad; retry after flake bumps)
   - Restore the meta-dir copy-in that 3b285ad removed (host `cp` to
     `$meta_dir/claude.json`, guest `cp` to `$host_home/.claude.json`).
4. `nix/sandbox-spec.nix` checklist — document "seeded by copy at launch".

## Non-goals

- No copy-back of sandbox changes to the host file (intentional: keeps
  sandbox activity out of host global state).
- No per-project persistence of the sandbox's own `.claude.json` across
  sessions (could be added later if losing in-sandbox trust prompts between
  sessions becomes annoying).
