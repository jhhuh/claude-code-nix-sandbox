# claude-code `/copy` in a sandbox needs a clipboard binary (xclip), not OSC 52

## Symptom

`/copy` inside a sandboxed claude session prints "Copied to clipboard …"
and writes the fallback file, but the host's X CLIPBOARD is never filled —
pasting elsewhere yields nothing. Works fine when claude runs unsandboxed.

## Mechanism (verified, not assumed)

claude-code's `/copy` does **not** use OSC 52 terminal escapes. Its binary
shells out to a platform clipboard **binary**:

```
$ grep -aoE 'xclip|xsel|wl-copy|wl-paste|pbcopy|-selection clipboard' \
    <claude-code>/bin/.claude-unwrapped | sort | uniq -c
   6 pbcopy            # macOS
   8 -selection clipboard
   7 wl-copy           # Wayland
  10 wl-paste
  23 xclip             # X11
  11 xsel              # X11
```

On X11 it runs `xclip -selection clipboard` (or `xsel`), which connects to
the X server over `$DISPLAY` using `$XAUTHORITY`. The sandbox already
forwards DISPLAY, the `/tmp/.X11-unix/Xn` socket, and Xauthority — but the
package set (`nix/sandbox-spec.nix`) shipped **no** clipboard binary, so
claude had nothing to exec and silently fell back to the file.

## Fix

Add `xclip` to `spec.packages` in `nix/sandbox-spec.nix`. Because the X
socket/Xauthority are already forwarded, xclip reaches the host CLIPBOARD
with no other change.

### Verify (round-trips through the real host X CLIPBOARD)

```bash
nix build .#sandbox
./result/bin/claude-sandbox --shell /some/dir <<'EOF'
printf 'hello' | xclip -selection clipboard        # exit 0 = connected to X
xclip -selection clipboard -o                        # prints 'hello'
EOF
```

A successful write+readback means xclip owns the CLIPBOARD selection on the
host X server. Caveat: xclip forks a holder process that serves the
selection; when the sandbox exits, the holder dies and the clipboard
empties unless a host clipboard manager grabbed a copy (standard xclip
behavior, same unsandboxed — not a regression).

## Debugging lesson (this one bit hard)

**You cannot probe host tool availability from inside the sandbox.** Running
`command -v xclip`, checking `~/.nix-profile` / `/run/current-system/sw`,
etc. from the agent's own shell reflects *that shell's* environment — which
is itself sandboxed — NOT the host. Early diagnosis wrongly concluded "the
host has no clipboard binaries, therefore OSC 52," built on exactly this
mistake. When a claim depends on the host's installed tools or PATH, you
must either get it from the user (who can see the host) or from a mechanism
you can actually observe (here: the compiled claude binary's own strings,
and running the real backend). Do not present sandbox-local observations as
host facts.

## Non-obvious extras

- Wayland hosts would need `wl-clipboard` instead of `xclip`; add it if a
  Wayland setup appears. X11 was the case here (`XDG_SESSION_TYPE=x11`).
- This is orthogonal to `--tmux` mode. claude never emits OSC 52, so nested
  tmux `set-clipboard`/`terminal-features` tuning does nothing for `/copy`.
