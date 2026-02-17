# Local CLI for managing sandboxes on a remote server via SSH
{
  writeShellApplication,
  openssh,
  curl,
  jq,
  tmux,
}:

writeShellApplication {
  name = "claude-remote";
  runtimeInputs = [ openssh curl jq tmux ];

  text = ''
    set -euo pipefail

    HOST="''${CLAUDE_REMOTE_HOST:-}"
    PORT="''${CLAUDE_REMOTE_PORT:-3000}"
    SSH_OPTS="''${CLAUDE_REMOTE_SSH_OPTS:-}"

    if [[ -z "$HOST" ]]; then
      echo "Error: CLAUDE_REMOTE_HOST is not set" >&2
      echo "Usage: CLAUDE_REMOTE_HOST=server claude-remote <command>" >&2
      exit 1
    fi

    # Helper: run curl on the remote via SSH
    # SSH concatenates args into one string for the remote shell,
    # so we must escape each argument for safe remote parsing.
    remote_api() {
      local method="$1" path="$2"
      shift 2
      local cmd
      cmd="curl -s -X $(printf '%q' "$method") $(printf '%q' "localhost:$PORT$path")"
      for arg in "$@"; do
        cmd+=" $(printf '%q' "$arg")"
      done
      # shellcheck disable=SC2086,SC2029
      ssh $SSH_OPTS "$HOST" "$cmd"
    }

    cmd="''${1:-help}"
    shift || true

    case "$cmd" in
      create)
        if [[ $# -lt 3 ]]; then
          echo "Usage: claude-remote create <name> <backend> <project-dir> [--no-network]" >&2
          exit 1
        fi
        name="$1"; backend="$2"; project_dir="$3"; shift 3
        network=true
        if [[ "''${1:-}" == "--no-network" ]]; then network=false; fi
        payload=$(jq -n \
          --arg name "$name" \
          --arg backend "$backend" \
          --arg project_dir "$project_dir" \
          --argjson network "$network" \
          '{name: $name, backend: $backend, project_dir: $project_dir, network: $network}')
        remote_api POST /api/sandboxes \
          -H 'Content-Type: application/json' \
          -d "$payload" | jq .
        ;;

      list|ls)
        remote_api GET /api/sandboxes | jq '.[] | {id: .id[0:8], name, backend, status, project_dir}'
        ;;

      attach)
        if [[ $# -lt 1 ]]; then
          echo "Usage: claude-remote attach <id-prefix>" >&2
          exit 1
        fi
        # Look up the full sandbox to get tmux session name
        id_prefix="$1"
        full=$(remote_api GET /api/sandboxes | jq -r ".[] | select(.id | startswith(\"$id_prefix\")) | .tmux_session")
        if [[ -z "$full" || "$full" == "null" ]]; then
          echo "Error: no sandbox found with id prefix $id_prefix" >&2
          exit 1
        fi
        # shellcheck disable=SC2086
        ssh $SSH_OPTS -t "$HOST" tmux attach -t "$full"
        ;;

      stop)
        if [[ $# -lt 1 ]]; then
          echo "Usage: claude-remote stop <id-prefix>" >&2
          exit 1
        fi
        id_prefix="$1"
        full_id=$(remote_api GET /api/sandboxes | jq -r ".[] | select(.id | startswith(\"$id_prefix\")) | .id")
        if [[ -z "$full_id" ]]; then
          echo "Error: no sandbox found" >&2; exit 1
        fi
        remote_api POST "/api/sandboxes/$full_id/stop"
        echo "Stopped $full_id"
        ;;

      delete|rm)
        if [[ $# -lt 1 ]]; then
          echo "Usage: claude-remote delete <id-prefix>" >&2
          exit 1
        fi
        id_prefix="$1"
        full_id=$(remote_api GET /api/sandboxes | jq -r ".[] | select(.id | startswith(\"$id_prefix\")) | .id")
        if [[ -z "$full_id" ]]; then
          echo "Error: no sandbox found" >&2; exit 1
        fi
        remote_api DELETE "/api/sandboxes/$full_id"
        echo "Deleted $full_id"
        ;;

      metrics)
        if [[ $# -ge 1 ]]; then
          id_prefix="$1"
          full_id=$(remote_api GET /api/sandboxes | jq -r ".[] | select(.id | startswith(\"$id_prefix\")) | .id")
          if [[ -z "$full_id" ]]; then
            echo "Error: no sandbox found" >&2; exit 1
          fi
          echo "=== Sandbox metrics ==="
          remote_api GET "/api/sandboxes/$full_id/metrics" | jq .
        fi
        echo "=== System metrics ==="
        remote_api GET /api/metrics/system | jq .
        ;;

      ui)
        echo "Forwarding localhost:$PORT to $HOST:$PORT"
        echo "Open http://localhost:$PORT in your browser"
        # shellcheck disable=SC2086
        ssh $SSH_OPTS -N -L "$PORT:localhost:$PORT" "$HOST"
        ;;

      help|--help|-h)
        echo "claude-remote — manage sandboxes on a remote server"
        echo ""
        echo "Environment:"
        echo "  CLAUDE_REMOTE_HOST    Remote server hostname (required)"
        echo "  CLAUDE_REMOTE_PORT    Manager port (default: 3000)"
        echo "  CLAUDE_REMOTE_SSH_OPTS  Extra SSH options"
        echo ""
        echo "Commands:"
        echo "  create <name> <backend> <dir> [--no-network]"
        echo "  list                  List sandboxes"
        echo "  attach <id>           Attach to sandbox tmux session"
        echo "  stop <id>             Stop a sandbox"
        echo "  delete <id>           Delete a sandbox"
        echo "  metrics [id]          Show system (and sandbox) metrics"
        echo "  ui                    Forward web dashboard via SSH tunnel"
        ;;

      *)
        echo "Unknown command: $cmd" >&2
        echo "Run 'claude-remote help' for usage." >&2
        exit 1
        ;;
    esac
  '';
}
