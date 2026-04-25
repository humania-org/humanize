#!/usr/bin/env bash
# Restart the Humanize Viz dashboard server.
#
# Usage:
#   viz-restart.sh <project_dir>                  # legacy positional
#   viz-restart.sh --project <path> \
#                  [--host <addr>] [--port <int>] \
#                  [--auth-token <tok>] [--trust-proxy]
#
# Every flag the underlying viz-start.sh accepts is forwarded
# verbatim. A plain `viz-restart.sh --project <path>` still works
# and re-launches with viz-start.sh's defaults (loopback bind, no
# auth); callers that started the daemon with custom --host /
# --port / --auth-token / --trust-proxy must repeat those flags
# here, otherwise the restarted daemon will silently drop back to
# the defaults and the previous access URL / token stop working.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse every flag that viz-start.sh understands so restart is a
# true equivalent of stop+start with the same configuration. The old
# implementation only captured --project and silently dropped
# --host / --port / --auth-token / --trust-proxy, which made a
# non-loopback daemon quietly revert to localhost on restart.
PROJECT_DIR="."
HOST=""
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
        --) shift ;;
        *) PROJECT_DIR="$1"; shift ;;
    esac
done
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Rebuild the viz-start argv in a deterministic order so the
# restarted daemon sees exactly the same config the caller gave us.
START_ARGS=(--project "$PROJECT_DIR")
[[ -n "$HOST" ]]    && START_ARGS+=(--host "$HOST")
[[ -n "$PORT" ]]    && START_ARGS+=(--port "$PORT")
[[ -n "$AUTH_TOKEN" ]] && START_ARGS+=(--auth-token "$AUTH_TOKEN")
[[ "$TRUST_PROXY" == "true" ]] && START_ARGS+=(--trust-proxy)

bash "$SCRIPT_DIR/viz-stop.sh" --project "$PROJECT_DIR" 2>/dev/null || true
sleep 1
exec bash "$SCRIPT_DIR/viz-start.sh" "${START_ARGS[@]}"
