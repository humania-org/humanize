#!/usr/bin/env bash
# Per-project tmux session name derivation for the viz dashboard daemon.
#
# Used by viz-start.sh, viz-stop.sh, and viz-status.sh so all three
# resolve the same tmux session name from a project path. Replaces the
# legacy global "humanize-viz" name that allowed one project's daemon to
# kill another project's running server.
#
# Source this file (do not execute) and call viz_tmux_session_name.

# Returns "humanize-viz-<8-hex>" derived from a stable hash of the
# absolute project path. Tmux session names cannot contain "." or ":"
# so a content-derived hex slug is the safest portable choice.
viz_tmux_session_name() {
    local project_dir="$1"
    if [[ -z "$project_dir" ]]; then
        echo "humanize-viz"
        return
    fi
    # Resolve to absolute path so different invocations (./ vs absolute)
    # land on the same session.
    if [[ -d "$project_dir" ]]; then
        project_dir="$(cd "$project_dir" 2>/dev/null && pwd)"
    fi
    local hash=""
    if command -v sha1sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$project_dir" | sha1sum | cut -c1-8)
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(printf '%s' "$project_dir" | shasum | cut -c1-8)
    elif command -v openssl >/dev/null 2>&1; then
        hash=$(printf '%s' "$project_dir" | openssl dgst -sha1 | awk '{print $NF}' | cut -c1-8)
    else
        # Last-resort fallback: sanitize the path itself (matches the
        # rule in scripts/humanize.sh and viz/server/rlcr_sources.py).
        hash=$(printf '%s' "$project_dir" | sed 's/[^A-Za-z0-9._-]/-/g' | sed 's/--*/-/g' | tr '[:upper:]' '[:lower:]')
        # Truncate so the resulting tmux name is not absurdly long.
        hash="${hash: -16}"
    fi
    echo "humanize-viz-${hash}"
}
