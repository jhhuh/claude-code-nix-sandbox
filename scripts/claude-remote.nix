# Local CLI for managing sandboxes on a remote server via SSH
{
  writeShellApplication,
  openssh,
  curl,
  jq,
  tmux,
  rsync,
  fswatch,
}:

writeShellApplication {
  name = "claude-remote";
  runtimeInputs = [ openssh curl jq tmux rsync fswatch ];

  text = ''
    set -euo pipefail

    # Load config file: ''${XDG_CONFIG_HOME:-~/.config}/claude-remote/config
    _cfg_host="" _cfg_port="" _cfg_ssh_opts=""
    _config_file="''${XDG_CONFIG_HOME:-$HOME/.config}/claude-remote/config"
    if [[ -f "$_config_file" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="''${line%%#*}"          # strip comments
        [[ -z "''${line// /}" ]] && continue  # skip blank
        key="''${line%%=*}"; val="''${line#*=}"
        key="''${key// /}"; val="''${val# }"; val="''${val% }"
        case "$key" in
          host)     _cfg_host="$val" ;;
          port)     _cfg_port="$val" ;;
          ssh_opts) _cfg_ssh_opts="$val" ;;
        esac
      done < "$_config_file"
    fi

    HOST="''${CLAUDE_REMOTE_HOST:-$_cfg_host}"
    PORT="''${CLAUDE_REMOTE_PORT:-''${_cfg_port:-3000}}"
    SSH_OPTS="''${CLAUDE_REMOTE_SSH_OPTS:-$_cfg_ssh_opts}"

    # Allow help without CLAUDE_REMOTE_HOST
    if [[ "''${1:-}" == "help" || "''${1:-}" == "--help" || "''${1:-}" == "-h" || $# -eq 0 ]]; then
      set -- help
    elif [[ -z "$HOST" ]]; then
      echo "Error: host is not set (use CLAUDE_REMOTE_HOST or config file)" >&2
      echo "Run 'claude-remote help' for usage." >&2
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

    # Helper: rsync local→remote
    do_rsync_to_remote() {
      local src="$1" dst="$2"
      rsync -az --delete --exclude='.git' --filter=':- .gitignore' \
        -e "ssh $SSH_OPTS" "$src/" "$HOST:$dst/"
    }

    # Helper: rsync remote→local
    do_rsync_from_remote() {
      local remote_dir="$1" local_dir="$2"
      rsync -az --delete --exclude='.git' --filter=':- .gitignore' \
        -e "ssh $SSH_OPTS" "$HOST:$remote_dir/" "$local_dir/"
    }

    cmd="''${1:-help}"
    shift || true

    case "$cmd" in
      create)
        if [[ $# -lt 3 ]]; then
          echo "Usage: claude-remote create <name> <backend> <project-dir> [--no-network] [--sync]" >&2
          exit 1
        fi
        name="$1"; backend="$2"; project_dir="$3"; shift 3
        network=true
        do_sync=false
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --no-network) network=false ;;
            --sync) do_sync=true ;;
          esac
          shift
        done
        if [[ "$do_sync" == "true" ]]; then
          echo "Syncing $project_dir → $HOST:$project_dir ..."
          do_rsync_to_remote "$project_dir" "$project_dir"
          echo "Sync complete."
        fi
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

      sync)
        if [[ $# -lt 1 ]]; then
          echo "Usage: claude-remote sync <local-dir> [remote-dir]" >&2
          exit 1
        fi
        local_dir="$1"
        remote_dir="''${2:-$local_dir}"
        echo "Syncing $local_dir → $HOST:$remote_dir ..."
        do_rsync_to_remote "$local_dir" "$remote_dir"
        echo "Sync complete."
        ;;

      watch)
        if [[ $# -lt 1 ]]; then
          echo "Usage: claude-remote watch <local-dir> [remote-dir]" >&2
          exit 1
        fi
        local_dir="$1"
        remote_dir="''${2:-$local_dir}"

        # Initial sync local→remote
        echo "Initial sync $local_dir → $HOST:$remote_dir ..."
        do_rsync_to_remote "$local_dir" "$remote_dir"
        echo "Initial sync complete. Watching for changes..."

        # Cleanup on exit
        cleanup() {
          echo ""
          echo "Stopping watch..."
          kill "$REMOTE_SYNC_PID" 2>/dev/null || true
          wait "$REMOTE_SYNC_PID" 2>/dev/null || true
          exit 0
        }
        trap cleanup INT TERM

        # Background: remote→local sync every 2s
        (
          while true; do
            sleep 2
            do_rsync_from_remote "$remote_dir" "$local_dir" 2>/dev/null && \
              echo "[remote→local] synced $(date +%H:%M:%S)" || true
          done
        ) &
        REMOTE_SYNC_PID=$!

        # Foreground: watch local→remote via fswatch with debounce
        fswatch -r --event Created --event Updated --event Removed --event Renamed \
          --exclude='\.git/' "$local_dir" | while read -r _event; do
          # Coalesce: drain any queued events (100ms window)
          while read -r -t 0.1 _extra; do :; done
          echo "[local→remote] syncing $(date +%H:%M:%S) ..."
          do_rsync_to_remote "$local_dir" "$remote_dir"
        done

        # If fswatch exits, clean up
        cleanup
        ;;

      help|--help|-h)
        echo "claude-remote — manage sandboxes on a remote server"
        echo ""
        echo "Configuration (env var > config file > default):"
        echo "  CLAUDE_REMOTE_HOST      Remote server hostname (required)"
        echo "  CLAUDE_REMOTE_PORT      Manager port (default: 3000)"
        echo "  CLAUDE_REMOTE_SSH_OPTS  Extra SSH options"
        echo ""
        echo "Config file: ''${XDG_CONFIG_HOME:-"$HOME/.config"}/claude-remote/config"
        echo "  host = myserver"
        echo "  port = 3000"
        echo "  ssh_opts = -i ~/.ssh/mykey"
        echo ""
        echo "Commands:"
        echo "  create <name> <backend> <dir> [--no-network] [--sync]"
        echo "  list                  List sandboxes"
        echo "  attach <id>           Attach to sandbox tmux session"
        echo "  stop <id>             Stop a sandbox"
        echo "  delete <id>           Delete a sandbox"
        echo "  metrics [id]          Show system (and sandbox) metrics"
        echo "  sync <dir> [remote]   One-shot rsync local→remote"
        echo "  watch <dir> [remote]  Continuous bidirectional sync"
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
