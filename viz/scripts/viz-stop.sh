#!/usr/bin/env bash
# Stop the Humanize Viz dashboard server for one project.
#
# Per-project tmux session names (T9) mean stopping one project's
# dashboard never touches another project's running server.
#
# Usage:
#   viz-stop.sh <project_dir>           # legacy positional
#   viz-stop.sh --project <path>        # current named flag

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

# `=$TMUX_SESSION` forces exact match so prefix collisions (or the
# generic "humanize-viz" fallback name) cannot cause an unrelated
# session to be killed.
if tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
    tmux kill-session -t "=$TMUX_SESSION"
    rm -f "$PORT_FILE" "$URL_FILE"
    echo "Viz server stopped for project: $PROJECT_DIR"
else
    rm -f "$PORT_FILE" "$URL_FILE"
    echo "Viz server is not running for project: $PROJECT_DIR"
fi
