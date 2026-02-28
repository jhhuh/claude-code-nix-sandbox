# REST API

The manager exposes a JSON API alongside the web dashboard. All endpoints listen on the configured `MANAGER_LISTEN` address (default `127.0.0.1:3000`).

## Endpoints

### List sandboxes

```
GET /api/sandboxes
```

Returns a JSON array of all sandboxes, sorted by creation time (newest first).

```bash
curl localhost:3000/api/sandboxes
```

### Get sandbox

```
GET /api/sandboxes/<id>
```

Returns a single sandbox by full UUID.

```bash
curl localhost:3000/api/sandboxes/<id>
```

### Create sandbox

```
POST /api/sandboxes
Content-Type: application/json
```

Request body:

```json
{
  "name": "my-project",
  "backend": "bubblewrap",
  "project_dir": "/home/user/project",
  "network": true
}
```

- `backend` — `"bubblewrap"`, `"container"`, or `"vm"`
- `network` — optional, defaults to `true`

Returns `201 Created` with the sandbox JSON on success.

```bash
curl -X POST localhost:3000/api/sandboxes \
  -H 'Content-Type: application/json' \
  -d '{"name":"test","backend":"bubblewrap","project_dir":"/tmp/test","network":true}'
```

### Stop sandbox

```
POST /api/sandboxes/<id>/stop
```

Returns `204 No Content` on success.

```bash
curl -X POST localhost:3000/api/sandboxes/<id>/stop
```

### Delete sandbox

```
DELETE /api/sandboxes/<id>
```

Returns `204 No Content` on success.

```bash
curl -X DELETE localhost:3000/api/sandboxes/<id>
```

### Get screenshot

```
GET /api/sandboxes/<id>/screenshot
```

Returns the latest screenshot as `image/png`. Returns `404` if no screenshot is available.

```bash
curl localhost:3000/api/sandboxes/<id>/screenshot -o screenshot.png
```

### Get sandbox metrics

```
GET /api/sandboxes/<id>/metrics
```

Returns Claude session metrics parsed from the sandbox's project directory (tokens used, tool calls, message count, etc.).

```bash
curl localhost:3000/api/sandboxes/<id>/metrics
```

### Get system metrics

```
GET /api/metrics/system
```

Returns system-wide metrics: CPU usage, memory, disk, and load averages.

```bash
curl localhost:3000/api/metrics/system
```

### Get logs

```
GET /api/sandboxes/<id>/logs
```

Returns the full log file (tmux pipe-pane output) as `text/plain`.

```bash
curl localhost:3000/api/sandboxes/<id>/logs
```

### Stream logs (WebSocket)

```
GET /ws/sandboxes/<id>/logs
```

Upgrades to a WebSocket connection. Sends the last 1000 lines as initial backlog, then pushes new lines in real time as the sandbox produces output.

## Sandbox object

```json
{
  "id": "a1b2c3d4-...",
  "name": "my-project",
  "backend": "bubblewrap",
  "project_dir": "/home/user/project",
  "status": "running",
  "display_num": 50,
  "tmux_session": "claude-a1b2c3d4",
  "pid_xvfb": 12345,
  "qemu_qmp_socket": null,
  "network": true,
  "created_at": "2025-01-15T10:30:00Z"
}
```

- `status` — `"running"`, `"stopped"`, or `"dead"`
- `display_num` — Xvfb display number (bubblewrap/container backends)
- `qemu_qmp_socket` — QMP socket path (VM backend)
- `tmux_session` — tmux session name for attaching
