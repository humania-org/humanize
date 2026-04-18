#!/usr/bin/env bash
# Restart the Humanize Viz dashboard server.
# Usage: viz-restart.sh [--project <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

bash "$SCRIPT_DIR/viz-stop.sh" "$PROJECT_DIR" 2>/dev/null || true
sleep 1
exec bash "$SCRIPT_DIR/viz-start.sh" "$PROJECT_DIR"
