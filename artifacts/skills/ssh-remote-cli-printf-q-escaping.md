# SSH Remote CLI: printf '%q' Argument Escaping

## Problem

When building a CLI that executes commands on a remote host via SSH, arguments get double-parsed: once by the local shell, once by the remote shell. JSON payloads, paths with spaces, and special characters (`{}`, `|`, `&`, `;`) break silently.

```bash
# BROKEN — SSH concatenates args, remote shell re-parses them
ssh host curl -X POST -d '{"name":"test"}' http://localhost:3000/api
# Remote sees: curl -X POST -d {name:test} http://localhost:3000/api
```

## Solution

Use `printf '%q'` to shell-escape each argument before building the SSH command string:

```bash
remote_api() {
  local method="$1"; shift
  local endpoint="$1"; shift

  local cmd
  cmd="curl -s -X $(printf '%q' "$method")"
  cmd+=" $(printf '%q' "http://localhost:${PORT}${endpoint}")"

  # Append remaining args (headers, data payloads)
  for arg in "$@"; do
    cmd+=" $(printf '%q' "$arg")"
  done

  # shellcheck disable=SC2029
  ssh $SSH_OPTS "$HOST" "$cmd"
}
```

`printf '%q'` adds backslash/quote escaping so the string survives the remote shell's parsing intact.

## ShellCheck SC2029

ShellCheck warns that variables in SSH commands are expanded locally. This is intentional — we're building the command string locally on purpose. Add `# shellcheck disable=SC2029` before the `ssh` call. In `writeShellApplication`, this info-level warning is treated as an error.

## Alternative: Heredoc approach

For very complex payloads, consider a heredoc:
```bash
ssh host 'bash -s' <<EOF
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name":"test","backend":"bubblewrap"}' \
  http://localhost:3000/api/sandboxes
EOF
```

But `printf '%q'` scales better for dynamic argument lists.

## References

- `scripts/claude-remote.nix` — full implementation of SSH-based CLI
- `artifacts/devlog_manager.md` — "CLI SSH quoting bug" entry
