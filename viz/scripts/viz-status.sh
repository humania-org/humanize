#!/usr/bin/env bash
# Check the status of the Humanize Viz dashboard server for one project.
#
# Per-project tmux session names (T9) mean checking one project's
# dashboard never affects another project's running server.
#
# Usage:
#   viz-status.sh <project_dir>           # legacy positional
#   viz-status.sh --project <path>        # current named flag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/viz-session-name.sh"

PROJECT_DIR="."
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT_DIR="$2"; shift 2 ;;
        --) shift ;;
        *) PROJECT_DIR="$1"; shift ;;
    esac
done
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

HUMANIZE_DIR="$PROJECT_DIR/.humanize"
PORT_FILE="$HUMANIZE_DIR/viz.port"
URL_FILE="$HUMANIZE_DIR/viz.url"
TMUX_SESSION="$(viz_tmux_session_name "$PROJECT_DIR")"

if [[ -f "$PORT_FILE" ]]; then
    port=$(cat "$PORT_FILE")
    # Probe the URL recorded by viz-start.sh (which knows the
    # configured bind), falling back to localhost when only the legacy
    # port file is present. This is what makes `--host 192.168.1.10`
    # deployments work — without it the localhost probe would reject
    # a healthy server as dead and tear down the session.
    if [[ -f "$URL_FILE" ]]; then
        probe_url=$(cat "$URL_FILE")
    else
        probe_url="http://localhost:$port"
    fi
    if curl -s --max-time 2 "$probe_url/api/health" >/dev/null 2>&1; then
        echo "Viz server running for project $PROJECT_DIR at $probe_url"
        exit 0
    fi
    # Stale port file for THIS project only.
    echo "Viz server is not running for project: $PROJECT_DIR (stale port file, cleaning up)."
    rm -f "$PORT_FILE" "$URL_FILE"
    # Use tmux's `=name` exact-match form so a generic "humanize-viz"
    # session name never accidentally matches a longer per-project
    # name (or vice versa). Project-specific names derived by
    # viz_tmux_session_name already carry an 8-hex suffix; the
    # exact-match syntax makes the intent explicit and robust.
    if tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
        tmux kill-session -t "=$TMUX_SESSION" 2>/dev/null || true
    fi
    exit 1
fi

echo "Viz server is not running for project: $PROJECT_DIR"
exit 1
