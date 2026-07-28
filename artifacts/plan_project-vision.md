# Project vision — handoff note

**Status: DRAFT. Not an approved spec.** The blueprint below was presented but
not yet approved; we stopped before writing a formal spec. Do not start
implementing from this document — resume the conversation first.

Date: 2026-07-28. Context: the project was started in Feb 2026 after a few
days of using Claude Code, without a long-run direction. This session was an
attempt to reclaim it with a clearer one.

## Decisions made (question asked → answer given)

1. **Audience** → *Personal daily driver now, expandable to agent-fleet
   infrastructure later.* Not OSS-first, not a teaching artifact.
2. **Fleet shape** → *Both local and remote, on the same substrate.* SSH is a
   transport detail, not a different product.
3. **Identity unit** → *Hybrid.* Instances are the real identity (generated
   id, N per project, addressable); the project directory is a convenience
   alias so bare `claude-sandbox` in a repo still does the obvious thing.
4. **Strategy for the dormant half** → *A: substrate first, freeze the
   manager.* Frozen means visibly marked and kept in `nix flake check` so it
   cannot rot silently — not deleted, not maintained, no new features.
5. **Coupling to Claude Code** → *All three levels*: agent-agnostic substrate
   with per-agent adapters, Claude-specifics isolated in one place, and a
   `doctor` that verifies assumptions. With a hard constraint, stated by the
   user and quoted here because it drives the architecture:

   > "we should be able to upgrade agent tool itself without rebuilding the
   > manager part"

## Evidence behind those decisions

Do not re-derive this; it took most of the session.

- **The project bifurcated early.** `nix/backends` has 61 commits and is
  current; `manager` (6), `nix/modules` (7), `scripts` (5) and `tests` (2)
  have been untouched since Feb–Mar 2026. 238 commits total, Feb 17 – Jul 25.
  Everything worked on this session was in the backends.
- **The manager is not rotted** — it builds fine with `--builders ''`. An
  earlier failure was the remote builder (`/setup: No such file or directory`
  while building initrd), not the code. The same builder problem affects
  `.#vm`.
- **The manager IS a systemd daemon** (`wantedBy multi-user.target`,
  `Restart=on-failure`, axum::serve plus monitor and screenshot loops), and
  its store path is baked into the unit's `ExecStart`.
- **The user's constraint is violated today.** Proven with
  `nix path-info -r ./result-manager`: the manager's closure contains
  `claude-code-2.1.220`, transitively via `claude-sandbox` →
  `claude-sandbox-path`. So bumping the agent changes the manager derivation,
  changes the unit, and `nixos-rebuild switch` **restarts a live supervisor
  daemon**.
- **There are two rival registries.** The manager keeps `state.json` with
  `pid_xvfb` and `reconcile_pids()`; the sandbox now keeps its own registry
  (pid + namespace inodes) in the per-project state dir. They are semantically
  incompatible: the manager allocates a display per *instance* and assumes it
  spawned a fresh one, but `claude-sandbox <dir>` now *joins* an existing
  sandbox for that project. Reviving the manager unchanged would have it
  silently attach to a running sandbox while believing it created one.
- **Docs have rotted.** `docs/src` has zero coverage of `--enter`, the state
  dir, nix-ld or uv, and three statements are now false (two about
  `virtualisation.vlans`, one placing tmux state in `<project-dir>/.tmux/`).
  The CLAUDE.md skill index lists 16 files; there are 18.

## The blueprint

```
L3  Orchestration    manager (systemd daemon) · claude-remote (SSH transport)
                     consumes the CLI · owns no sandbox state   [FROZEN now]
L2  Agent adapters   claude-code · opencode · …
                     what to seed · notice text · extra tools · doctor checks
L1  Substrate CLI    identity (instance id + project alias)      [the product]
                     verbs: run · enter · stop · list · status · doctor
                     state: project-persistent | instance-runtime
L0  Isolation        bubblewrap · nspawn · QEMU                  [durable]
```

Five invariants:

1. **The CLI is the substrate — there is no second API.** A remote sandbox is
   the same CLI invoked on that host. The manager's REST API is optional sugar
   over the CLI, never the source of truth.
2. **The agent is a parameter, not a build dependency.** Agent upgrades must
   never enter the daemon's closure.
3. **The sandbox owns "what is running."** Everything else reads it.
4. **Two state scopes.** Project-persistent (chromium profile, `~/.local`,
   `/tmp`, `tmux.conf`) versus instance-runtime (pid, ns inodes, display).
5. **Agent assumptions are checked, not assumed** (`doctor`), run on flake bumps.

Concretely against today's code: `spec.packages` loses the agent; backends
gain an `--agent` parameter; the `.claude.json` seed and notice injection move
out of all three backends into one adapter; `$state_dir` grows an `instances/`
level; `list`/`status`/`doctor` are added with `--json`; the manager gets a
visible FROZEN marker.

## Work packages

Each gets its own spec → plan → implementation.

- **WP1 — Substrate core.** Identity, verbs, JSON output, single source of
  truth. Pays off in daily use immediately.
- **WP2 — Agent parameterization.** Adapters, `doctor`, agent out of the
  closure. This is what delivers the no-daemon-restart constraint.
- **WP3 — Repo hygiene.** Doc tiering (current-truth vs historical), drift
  fixes, mechanical checks, freeze markers.
- **WP4 — Manager as consumer.** Only after WP1/WP2 are stable.

Suggested order: WP1 → WP2 → WP3. WP2's adapter boundary is much easier to
draw once identity and verbs are settled.

## Open questions — resume here

1. **Blueprint approval.** It was presented; the session stopped before an
   answer. Confirm or amend before writing a spec.
2. **Which mode is the default for the agent parameter?** Proposed
   reproducible-by-default (agent pinned by the flake) with an override for
   fast upgrades. The user may prefer the override as default and pinning as
   opt-in. Unanswered.
3. **Is "no second API" too strict?** Asked whether the manager should ever
   own state the CLI does not know about. Unanswered.

## Also worth knowing

- A separate `opencode-nix-sandbox` repo exists and the user has been
  hand-porting commits into it (per the Claude Code usage report). The
  agent-adapter split in WP2 would absorb that duplication — this is a real
  motivator, not a hypothetical.
- Deferred runtime verifications are recorded at the end of
  `artifacts/devlog.md`: container `--enter`/`--stop` and VM `--enter` are
  build-verified only.
- Two premises I got wrong this session, both corrected in place, both worth
  imitating as a habit rather than repeating as mistakes: a skill file's claim
  about chromium's socket naming drove a whole design round before the
  upstream source contradicted it, and the `.#vm` build failure was blamed on
  nixpkgs when the error named our own flake. Read primary sources.
