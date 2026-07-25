# Plan: sandbox toolchain gap + persistence notice

## Motivation

The Claude Code usage report (`report-2026-07-25-073447.html`) ranks
"Sandbox and PATH environment mismatches" as the largest friction category,
citing missing `awk`/`sed`/`grep` breaking scripts, and work landing outside
the persistent mount.

Measured inside a live bubblewrap sandbox, both claims check out:

```
sed awk xargs jq curl wget less which file diff patch make tar gzip -> MISSING
grep, find -> bash *functions* injected by claude-code (ugrep/bfs wrappers),
              not binaries; they exist only in the interactive shell, so any
              script, Makefile, or subprocess calling them fails
python3    -> present (3.14.6), but `python3 -m pip` -> No module named pip
```

`spec.packages` shipped `coreutils` and nothing else from the standard text
utility set. `coreutils` provides none of grep/sed/awk/find.

## Goals (verifiable)

1. Every tool in the list below resolves to a real binary inside the sandbox
   when invoked from a **non-interactive subprocess** (not just the Bash tool
   shell, where claude's shell functions mask the gap).
   Verify: `claude-sandbox --shell` running a script that calls each tool via
   `command -v`, asserting zero MISSING.
2. The appended system prompt names the resolved project directory as the only
   persistent location and states that everything else is discarded on exit.
   Verify: `claude-sandbox <dir> -- --version` still works (notice is well
   formed / correctly quoted), and the composed notice string echoes with the
   real path interpolated.

Out of scope (raised, deliberately deferred): `claude --settings` guardrail
deny-rules, per-sandbox network namespace.

## Steps

1. `nix/sandbox-spec.nix`: extend `packages` with text-processing, archive,
   network, and process/dev tools. User confirmed closure size is not a
   constraint. Swap `python3` for `python3.withPackages (ps: [ ps.pip ])`.
   -> verify: `nix build .#sandbox` succeeds.
2. `nix/sandbox-spec.nix`: add `persistenceNotice`, a function of a *shell
   expansion string* (e.g. `"$project_dir"`) rather than a literal path,
   because the persistent path is only known at launch.
   -> verify: `nix-instantiate --parse` clean.
3. Backends (`bubblewrap.nix:75`, `container.nix:120`, `vm.nix:251`): append it
   to `sandbox_notice`. Static half stays `lib.escapeShellArg`-quoted; dynamic
   half is a bash double-quoted segment so `$project_dir` expands at runtime:
   ```
   sandbox_notice=<escaped static>"<nix-interpolated text containing $project_dir>"
   ```
   -> verify: `nix build .#sandbox .#container` (ShellCheck runs as error).

## Risks / notes

- `persistenceNotice` text must contain no `"`, backtick, or `$` other than the
  project-dir reference, since it lands inside bash double quotes.
- Adding real `grep`/`find` binaries does **not** change interactive behavior:
  claude's shell functions still take precedence over PATH. This only repairs
  the subprocess path, so no regression surface.
- `.#vm` cannot be built: pre-existing, unrelated `virtualisation.vlans`
  nixpkgs regression. VM edit verified by parse + inspection only.
- `pip` cannot install into the read-only nix store; it is useful via
  `python3 -m venv` / `--user`. Shipping it removes the hard failure, not the
  need for a venv.
