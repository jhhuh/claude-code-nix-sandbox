# Web Dashboard

The manager includes a web dashboard for visual sandbox management. Access it via `claude-remote ui` (SSH tunnel) or directly if you can reach the manager's listen address.

## Features

- **Sandbox list** — all sandboxes with status badges, backend type, and creation time
- **Live screenshots** — captured every 2 seconds from Xvfb or QEMU QMP
- **Sandbox detail** — individual page with live screenshot feed and Claude session metrics
- **Create form** — HTML form for creating new sandboxes
- **System metrics** — CPU, memory, disk usage

## Technology

The dashboard is server-rendered HTML with [htmx](https://htmx.org/) for auto-refreshing fragments. There is no JavaScript build step — htmx and CSS are vendored as static files, and HTML templates are compiled into the binary via [askama](https://github.com/djc/askama).

### htmx fragments

The dashboard uses htmx polling to keep content fresh without full page reloads:

| Fragment endpoint | Description |
|---|---|
| `/fragments/sandbox-list` | Sandbox list on the index page |
| `/fragments/system-metrics` | System metrics display |
| `/fragments/sandboxes/<id>/claude-metrics` | Claude session metrics for a sandbox |
| `/fragments/sandboxes/<id>/screenshot` | Live screenshot `<img>` tag |

## Pages

| URL | Description |
|---|---|
| `/` | Index — sandbox list + system metrics |
| `/new` | Create sandbox form |
| `/sandboxes/<id>` | Sandbox detail — screenshot + metrics |
