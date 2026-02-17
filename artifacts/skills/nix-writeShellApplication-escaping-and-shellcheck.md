# Nix writeShellApplication: Escaping and ShellCheck Gotchas

## Problem

`writeShellApplication` has two non-obvious constraints that interact badly:

1. **Nix `''` strings interpolate `${...}` everywhere** — including inside bash comments, double-quoted strings, and heredocs. Every `${VAR}` in the bash script is treated as Nix interpolation unless escaped.

2. **ShellCheck runs with `-e` (errors)** — `writeShellApplication` treats all ShellCheck warnings as build-time errors. This is stricter than most CI setups.

## Solutions

### Escaping bash `${}` in Nix `''` strings

Use `''${` to produce a literal `${` in the output:

```nix
text = ''
  # Config location: ''${XDG_CONFIG_HOME:-~/.config}/myapp/config
  value="''${SOME_VAR:-default}"
'';
```

This applies even in comments! Nix doesn't know what a "comment" is — it just sees `${...}` and interpolates.

### Common ShellCheck failures

**SC2155** (declare and assign separately):
```bash
# WRONG — ShellCheck error in writeShellApplication
export FOO="$(some_command)"

# RIGHT — split declare and assign
FOO="$(some_command)"
export FOO
```

**SC2029** (variable in SSH command):
```bash
# This triggers SC2029 (info level, but writeShellApplication treats as error)
ssh host "cd $dir && ls"

# Fix: disable the check
# shellcheck disable=SC2029
ssh host "cd $dir && ls"
```

**Quoting in array assignments** — ShellCheck requires quoting even for simple numeric variables:
```bash
real_uid="$(id -u)"
# WRONG — SC2086
echo "user:x:$real_uid:$real_gid:..."
# RIGHT
echo "user:x:${real_uid}:${real_gid}:..."
```

## When This Matters

Every `writeShellApplication` in this project (all backends, CLI scripts). The build fails at eval time with cryptic Nix interpolation errors, or at ShellCheck time with unexpected lint failures.

## References

- `scripts/claude-remote.nix` — SC2029 disable for SSH commands
- `nix/backends/vm.nix` — SC2155 fix for `export NIX_DISK_IMAGE`
- `nix/backends/container.nix` — quoting in passwd/group generation
