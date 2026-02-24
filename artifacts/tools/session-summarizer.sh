#!/usr/bin/env bash
# session-summarizer.sh — Extract human-readable conversation from Claude Code JSONL sessions
#
# Usage:
#   ./session-summarizer.sh <session.jsonl>              # full conversation (text only)
#   ./session-summarizer.sh --user-only <session.jsonl>  # human messages only
#   ./session-summarizer.sh --commits <session.jsonl>    # git commits made during session
#   ./session-summarizer.sh --tools <session.jsonl>      # tool use summary (names + counts)
#   ./session-summarizer.sh --overview <session.jsonl>   # compact: user msgs + assistant summaries
#
# Session files live in: ~/.claude/projects/<encoded-project-path>/<session-id>.jsonl
#
# JSONL structure:
#   Each line is a JSON object with .type = user|assistant|system|progress|queue-operation|file-history-snapshot
#   - user: .message.content is string or [{type:"text",text:"..."},...] — may include tool_result blocks
#   - assistant: .message.content is [{type:"text",text:"..."}, {type:"tool_use",...}, {type:"thinking",...}]
#   - progress/queue-operation/file-history-snapshot: metadata, skip for summarization

set -euo pipefail

mode="full"
if [[ "${1:-}" == "--user-only" ]]; then
  mode="user-only"; shift
elif [[ "${1:-}" == "--commits" ]]; then
  mode="commits"; shift
elif [[ "${1:-}" == "--tools" ]]; then
  mode="tools"; shift
elif [[ "${1:-}" == "--overview" ]]; then
  mode="overview"; shift
fi

file="${1:?Usage: session-summarizer.sh [--user-only|--commits|--tools|--overview] <session.jsonl>}"

if [[ ! -f "$file" ]]; then
  echo "Error: file not found: $file" >&2
  exit 1
fi

case "$mode" in
  full)
    # Extract user text + assistant text, skip tool_use/tool_result/thinking blocks
    jq -r '
      if .type == "user" then
        "\n--- USER ---\n" + (
          if (.message.content | type) == "string" then
            .message.content
          else
            [.message.content[]? | select(.type == "text") | .text] | join("\n")
          end
        )
      elif .type == "assistant" then
        "\n--- ASSISTANT ---\n" + (
          [.message.content[]? | select(.type == "text") | .text] | join("\n")
        )
      else empty end
    ' "$file" | sed '/^$/d'
    ;;

  user-only)
    # Just the human messages — useful for understanding what was asked
    jq -r '
      select(.type == "user") |
      if (.message.content | type) == "string" then
        .message.content
      else
        [.message.content[]? | select(.type == "text") | .text] | join("\n")
      end |
      select(length > 0)
    ' "$file" | head -200
    ;;

  commits)
    # Extract git commit commands from tool results
    jq -r '
      select(.type == "assistant") |
      [.message.content[]? | select(.type == "tool_use" and .name == "Bash") | .input.command] |
      .[] | select(test("git commit"))
    ' "$file" 2>/dev/null
    ;;

  tools)
    # Tool use frequency — shows what actions the session involved
    jq -r '
      select(.type == "assistant") |
      [.message.content[]? | select(.type == "tool_use") | .name] | .[]
    ' "$file" | sort | uniq -c | sort -rn
    ;;

  overview)
    # Compact overview: user messages + first line of each assistant response
    jq -r '
      if .type == "user" then
        "\n>> " + (
          if (.message.content | type) == "string" then
            .message.content
          else
            [.message.content[]? | select(.type == "text") | .text] | join("\n")
          end
        ) | split("\n")[0:3] | join("\n")
      elif .type == "assistant" then
        "   " + (
          [.message.content[]? | select(.type == "text") | .text] | join(" ") | split("\n")[0:2] | join(" ")
        )[:200]
      else empty end |
      select(length > 3)
    ' "$file"
    ;;
esac
