# Bubblewrap: Dynamic Bash Arrays for Optional Flags

## Pattern

When building a `bwrap` command with many conditional flags (display forwarding, D-Bus, GPU, audio, auth), use **bash arrays** instead of inline conditionals or string concatenation:

```bash
# Declare arrays for each concern
x11_args=()
dbus_args=()
gpu_args=()
audio_args=()

# Conditionally populate
if [[ -n "${DISPLAY:-}" ]]; then
  display_nr="${DISPLAY/#*:}"
  display_nr="${display_nr/%.*}"
  x11_args+=(--tmpfs /tmp/.X11-unix)
  x11_args+=(--ro-bind-try "/tmp/.X11-unix/X$display_nr" "/tmp/.X11-unix/X$display_nr")
fi

if [[ -d /dev/dri ]]; then
  gpu_args+=(--dev-bind /dev/dri /dev/dri)
fi

# Expand all arrays in the final command
exec bwrap \
  --die-with-parent \
  "${x11_args[@]}" \
  "${dbus_args[@]}" \
  "${gpu_args[@]}" \
  "${audio_args[@]}" \
  --chdir "$project_dir" \
  "${entrypoint[@]}"
```

## Why This Works Well

1. **Empty arrays expand to nothing** — `"${empty_array[@]}"` produces zero arguments, not an empty string. No need for `if/else` around the bwrap call.

2. **Separation of concerns** — Each feature (X11, D-Bus, GPU, audio, git, etc.) has its own array. Easy to add, remove, or debug independently.

3. **Safe quoting** — Array elements preserve whitespace and special characters. No word-splitting surprises.

4. **Readable** — The final `bwrap` call is a clean list of array expansions, not a tangle of `$(if ...; then ...; fi)`.

## Anti-Patterns

```bash
# BAD — string concatenation, word-splitting risk
EXTRA_FLAGS=""
if [[ -d /dev/dri ]]; then
  EXTRA_FLAGS+="--dev-bind /dev/dri /dev/dri "
fi
bwrap $EXTRA_FLAGS ...  # word-splits, breaks on paths with spaces

# BAD — inline conditionals in the command
bwrap \
  $(if [[ -d /dev/dri ]]; then echo "--dev-bind /dev/dri /dev/dri"; fi) \
  ...  # echo output is word-split by the shell
```

## Scope

This pattern is used in all three backends (`bubblewrap.nix`, `container.nix`, `vm.nix`). The container backend uses it for `nspawn_args` arrays; the VM backend uses it for `qemu_flags`.

## References

- `nix/backends/bubblewrap.nix` — canonical implementation with ~10 separate flag arrays
- `nix/backends/container.nix` — same pattern for nspawn args
