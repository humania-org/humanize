#!/usr/bin/env bash
#
# Deterministic project-root resolver for all humanize hooks and scripts.
#
# Resolution priority:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code, stable across `cd` within a session)
#   2. git rev-parse --show-toplevel (nearest enclosing repo)
#   3. Non-zero return.
#
# pwd is intentionally NOT used as a fallback: it drifts with `cd`
# invocations during a session and silently causes state.md lookups
# under .humanize/rlcr/ to miss the active loop directory.
#
# The resolved path is passed through realpath so symlinked prefixes
# (e.g. /Users/x vs /private/Users/x on macOS, or /var vs /private/var)
# do not diverge between setup-time and hook-time resolution.
#
# Path-comparison sites in validators must mirror this by canonicalizing
# the user-provided side as well; use the companion `canonicalize_path`
# helper below.
#

if [[ -n "${_HUMANIZE_PROJECT_ROOT_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_HUMANIZE_PROJECT_ROOT_SOURCED=1

# resolve_project_root
#
# Prints the resolved project root to stdout. Returns 0 on success,
# 1 when neither CLAUDE_PROJECT_DIR nor a git toplevel is available.
#
# Callers that must have a project root should handle the failure:
#
#   PROJECT_ROOT="$(resolve_project_root)" || exit 0   # hook: allow natural stop
#   PROJECT_ROOT="$(resolve_project_root)" || {        # setup: hard error
#       echo "Error: cannot determine humanize project root" >&2
#       exit 1
#   }
#
resolve_project_root() {
    local root="${CLAUDE_PROJECT_DIR:-}"
    if [[ -z "$root" ]]; then
        root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    fi
    if [[ -z "$root" ]]; then
        return 1
    fi

    local canonical
    canonical=$(canonicalize_path "$root")
    printf '%s\n' "${canonical:-$root}"
}

# canonicalize_path
#
# Prints the realpath of the input path. If the path itself does not
# exist yet (common for write validation before the file is created),
# canonicalizes the parent directory and reattaches the basename.
# If realpath is unavailable and python3 is missing, prints the input
# path verbatim.
#
# Empty input prints nothing and returns 0.
#
canonicalize_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 0
    fi

    local canonical=""

    if canonical=$(realpath "$path" 2>/dev/null) && [[ -n "$canonical" ]]; then
        printf '%s\n' "$canonical"
        return 0
    fi

    # Path does not exist: canonicalize parent, reattach basename.
    local parent base
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")
    if canonical=$(realpath "$parent" 2>/dev/null) && [[ -n "$canonical" ]]; then
        printf '%s/%s\n' "${canonical%/}" "$base"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        canonical=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || true)
        if [[ -n "$canonical" ]]; then
            printf '%s\n' "$canonical"
            return 0
        fi
    fi

    printf '%s\n' "$path"
}
