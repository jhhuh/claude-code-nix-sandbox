# Claude Code Session JSONL Extraction

## Problem

Claude Code session files (`~/.claude/projects/<encoded-path>/<session-id>.jsonl`) can be 1-11MB+. Loading them directly into an LLM context window is impractical. But they contain valuable history: what was attempted, what failed, what decisions were made.

## Session File Location

Path encoding: `/home/user/project` → `~/.claude/projects/-home-user-project/<uuid>.jsonl`

Subagent sessions: `<project-dir>/<session-id>/subagents/agent-<id>.jsonl`

## JSONL Structure

Each line is a JSON object with a top-level `.type`:

| Type | Content | Useful? |
|---|---|---|
| `user` | Human messages | Yes — shows what was asked |
| `assistant` | AI responses (text + tool_use + thinking) | Partially — text is useful, tool_use/results are bulk |
| `system` | System prompts | Rarely |
| `progress` | Streaming progress | No |
| `queue-operation` | Internal queue ops | No |
| `file-history-snapshot` | File state snapshots | No |

### User message content

`.message.content` is either:
- A string (plain text message)
- An array of `{type, text}` blocks — may include `tool_result` blocks (verbose, skip these)

### Assistant message content

`.message.content` is an array with:
- `{type: "text", text: "..."}` — the actual response
- `{type: "tool_use", name: "...", input: {...}}` — tool calls (bulk of the data)
- `{type: "thinking", thinking: "..."}` — reasoning (optional)

## Extraction Modes

### Overview (most useful for catch-up)

```bash
jq -r '
  if .type == "user" then
    "\n>> " + (if (.message.content | type) == "string" then .message.content
    else [.message.content[]? | select(.type == "text") | .text] | join("\n") end
    ) | split("\n")[0:3] | join("\n")
  elif .type == "assistant" then
    "   " + ([.message.content[]? | select(.type == "text") | .text] | join(" ")
    | split("\n")[0:2] | join(" "))[:200]
  else empty end | select(length > 3)
' session.jsonl
```

### User messages only

```bash
jq -r 'select(.type == "user") |
  if (.message.content | type) == "string" then .message.content
  else [.message.content[]? | select(.type == "text") | .text] | join("\n") end |
  select(length > 0)
' session.jsonl
```

### Tool use frequency

```bash
jq -r 'select(.type == "assistant") |
  [.message.content[]? | select(.type == "tool_use") | .name] | .[]
' session.jsonl | sort | uniq -c | sort -rn
```

### Git commits made

```bash
jq -r 'select(.type == "assistant") |
  [.message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command] |
  .[] | select(test("git commit"))
' session.jsonl
```

## Tool

See `artifacts/tools/session-summarizer.sh` for a ready-to-use script with all modes.

## Tips

- Start with `--overview` or `--user-only` to understand what happened
- Use `--tools` to see the shape of work (lots of Edit = refactoring, lots of Bash = debugging)
- Subagent sessions are usually smaller and more focused
- Sort session files by date (`ls -lt`) to find the most recent
- File size correlates roughly with session length: <100K = short, 100K-500K = medium, 500K+ = long

## References

- `artifacts/tools/session-summarizer.sh` — extraction script
- `manager/src/metrics.rs` — the manager's own JSONL parser for Claude metrics
