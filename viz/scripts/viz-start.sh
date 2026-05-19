#!/usr/bin/env bash
# Launch the Humanize Viz dashboard server in a per-project tmux session.
#
# This script is invoked by the `--daemon` path of `humanize monitor web`
# and may also be run directly. The legacy positional `<project>` form is
# kept for backward compatibility; new callers should use the named flags.
#
# Usage:
#   viz-start.sh <project_dir>                                        # legacy
#   viz-start.sh --project <path> [--host <addr>] [--port <int>] \
#                                 [--auth-token <token>]              # current

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIZ_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REQUIREMENTS="$VIZ_ROOT/server/requirements.txt"
APP_ENTRY="$VIZ_ROOT/server/app.py"
STATIC_DIR="$VIZ_ROOT/static"

# Source the per-project tmux session naming helper so start/stop/status
# all derive the same name from the project path.
source "$SCRIPT_DIR/viz-session-name.sh"

# Parse args. Accept legacy positional <project> for backward compat.
PROJECT_DIR="."
HOST="127.0.0.1"
PORT=""
AUTH_TOKEN=""
TRUST_PROXY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT_DIR="$2"; shift 2 ;;
        --host)    HOST="$2"; shift 2 ;;
        --port)    PORT="$2"; shift 2 ;;
        --auth-token) AUTH_TOKEN="$2"; shift 2 ;;
        --trust-proxy) TRUST_PROXY=true; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | head -n -1
            exit 0
            ;;
        --)
            shift
            ;;
        *)
            # First non-flag positional is the project dir (legacy form).
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

HUMANIZE_DIR="$PROJECT_DIR/.humanize"
VENV_DIR="$HUMANIZE_DIR/viz-venv"
PORT_FILE="$HUMANIZE_DIR/viz.port"
URL_FILE="$HUMANIZE_DIR/viz.url"

# Per-project tmux session name (T9): each project gets its own slot so
# starting one project's daemon never kills another project's running
# server. The legacy global "humanize-viz" name is gone.
TMUX_SESSION="$(viz_tmux_session_name "$PROJECT_DIR")"

if [[ ! -d "$HUMANIZE_DIR" ]]; then
    echo "Error: No .humanize/ directory found in $PROJECT_DIR" >&2
    echo "This command must be run in a project with humanize initialized." >&2
    exit 1
fi

# Reject remote bind without a token before doing any other work.
if [[ "$HOST" != "127.0.0.1" && "$HOST" != "::1" && "$HOST" != "localhost" ]]; then
    if [[ -z "$AUTH_TOKEN" && -z "${HUMANIZE_VIZ_TOKEN:-}" ]]; then
        echo "Error: --host $HOST requires --auth-token (or HUMANIZE_VIZ_TOKEN)" >&2
        exit 2
    fi
fi

# If THIS project already has a running server, reuse it. We probe
# the visible URL recorded by a previous viz-start.sh (in viz.url),
# falling back to localhost when only the port file is present
# (older deployments). Probing the configured bind matters because
# `--host 192.168.1.10` does NOT listen on localhost, so a localhost
# probe would mis-detect a healthy server as dead.
if [[ -f "$PORT_FILE" ]]; then
    existing_port=$(cat "$PORT_FILE")
    if [[ -f "$URL_FILE" ]]; then
        existing_url=$(cat "$URL_FILE")
    else
        existing_url="http://localhost:$existing_port"
    fi
    if curl -s --max-time 2 "$existing_url/api/health" >/dev/null 2>&1; then
        echo "Viz server already running for this project at $existing_url"
        exit 0
    fi
    rm -f "$PORT_FILE" "$URL_FILE"
fi

# If THIS project's tmux session already exists but the server is dead,
# clean it up. `=$TMUX_SESSION` forces exact match so we never touch
# an unrelated session whose name happens to share a prefix (or the
# generic "humanize-viz" fallback).
if tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
    echo "Cleaning up stale tmux session for this project: $TMUX_SESSION"
    tmux kill-session -t "=$TMUX_SESSION" 2>/dev/null || true
fi

# Create venv if it does not exist.
if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    echo "Installing dependencies..."
    "$VENV_DIR/bin/pip" install --quiet -r "$REQUIREMENTS"
    echo "Dependencies installed."
elif [[ "$REQUIREMENTS" -nt "$VENV_DIR/.requirements_installed" ]]; then
    echo "Updating dependencies..."
    if ! "$VENV_DIR/bin/pip" install --quiet -r "$REQUIREMENTS"; then
        # Leave the marker untouched so the next launch retries the
        # upgrade instead of silently starting with missing packages.
        echo "Error: pip install failed during dependency refresh" >&2
        exit 1
    fi
    touch "$VENV_DIR/.requirements_installed"
fi
touch "$VENV_DIR/.requirements_installed"

# Pick a port if not specified. Per-project port file means parallel
# projects do not collide.
#
# The probe host must match what Flask's app.run() will actually try
# to bind. Loopback aliases and wildcard binds (0.0.0.0, ::) are
# safe to probe via localhost because wildcards also listen on the
# loopback interface, so a localhost probe catches conflicts there.
# But a specific non-loopback bind (e.g. 192.168.1.10) does NOT
# listen on localhost, so a localhost-only probe would report a
# port as free even when another service owns it on the external
# interface — and then app.run would die with EADDRINUSE. Probing
# the configured host directly makes remote mode startup reliable.
find_port() {
    local probe_host
    case "$HOST" in
        127.0.0.1|::1|localhost|0.0.0.0|::)
            probe_host="localhost"
            ;;
        *)
            probe_host="$HOST"
            ;;
    esac
    for candidate in $(seq 18000 18099); do
        if ! (echo >/dev/tcp/$probe_host/$candidate) 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    echo "Error: No available port in range 18000-18099" >&2
    return 1
}

if [[ -z "$PORT" ]]; then
    PORT=$(find_port)
fi
echo "$PORT" > "$PORT_FILE"

# Persist the visible URL so viz-status.sh / viz-stop.sh and the
# stale-port path above can probe the right host. Loopback binds
# expose the dashboard at localhost; non-loopback binds expose it at
# the configured host (the actual address browsers will reach).
visible_host_for_url="$HOST"
case "$HOST" in
    127.0.0.1|::1|localhost|0.0.0.0|::)
        # All loopback aliases AND the wildcard binds are reachable via
        # localhost from this machine, so probe localhost for the
        # liveness check. Wildcard binds also listen on the loopback
        # interface, so this is correct (and avoids needing to know
        # which external interface to probe).
        visible_host_for_url="localhost"
        ;;
esac
# RFC 3986 requires IPv6 addresses to be bracketed in URLs so the
# port separator is unambiguous. Without this, curl, browsers, and
# viz-status.sh all treat `http://<ipv6>:<port>` as an invalid URL
# because the trailing `:<N>` fragments of the address collide with
# the port separator. Loopback/wildcard binds already collapsed to
# "localhost" above (no colon), so this only wraps specific IPv6
# addresses and is a no-op for IPv4/localhost.
case "$visible_host_for_url" in
    *:*)
        visible_host_for_url="[${visible_host_for_url}]"
        ;;
esac
echo "http://${visible_host_for_url}:${PORT}" > "$URL_FILE"

# Build the python command, forwarding every flag.
PY_ARGS=(
    "$VENV_DIR/bin/python" "$APP_ENTRY"
    --host "$HOST"
    --port "$PORT"
    --project "$PROJECT_DIR"
    --static "$STATIC_DIR"
)
if [[ -n "$AUTH_TOKEN" ]]; then
    PY_ARGS+=(--auth-token "$AUTH_TOKEN")
fi
if [[ "$TRUST_PROXY" == "true" ]]; then
    PY_ARGS+=(--trust-proxy)
fi

# Launch in the per-project tmux session.
tmux new-session -d -s "$TMUX_SESSION" "${PY_ARGS[@]}"

visible_host="$HOST"
[[ "$HOST" == "127.0.0.1" || "$HOST" == "::1" ]] && visible_host="localhost"
echo "Viz server starting on http://${visible_host}:${PORT}"

# Readiness probe against the canonical URL we just wrote to viz.url.
# Probing "localhost" here would lie for --host <specific-ip> daemons
# (a healthy server never answers on localhost for those binds), and
# a process that dies on startup would also sail through unnoticed,
# leaving stale viz.port / viz.url + a misleading "ready" banner.
# Track whether any probe succeeded so the launcher can fail closed
# when the server never becomes reachable.
probe_url=$(cat "$URL_FILE")
ready="false"
for _ in $(seq 1 10); do
    if curl -s --max-time 1 "$probe_url/api/health" >/dev/null 2>&1; then
        ready="true"
        break
    fi
    sleep 0.5
done

if [[ "$ready" != "true" ]]; then
    echo "Error: viz dashboard did not become reachable at $probe_url within 5s." >&2
    echo "Inspect the tmux session for startup errors: tmux attach -t $TMUX_SESSION" >&2
    rm -f "$PORT_FILE" "$URL_FILE"
    exit 1
fi

# Open browser only when binding to the local machine.
if [[ "$HOST" == "127.0.0.1" || "$HOST" == "::1" || "$HOST" == "localhost" ]]; then
    if command -v xdg-open &>/dev/null; then
        xdg-open "http://localhost:$PORT" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "http://localhost:$PORT" 2>/dev/null &
    elif command -v wslview &>/dev/null; then
        wslview "http://localhost:$PORT" 2>/dev/null &
    else
        echo "Open http://localhost:$PORT in your browser."
    fi
fi

echo "Viz dashboard is ready at http://${visible_host}:${PORT}"
echo "Tmux session for this project: $TMUX_SESSION"
echo "Run 'viz-stop.sh --project $PROJECT_DIR' to stop the dashboard."
