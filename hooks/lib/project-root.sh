#!/usr/bin/env bash
#
# Deterministic project-root resolver for all humanize hooks and scripts.
#
# Resolution priority:
#   1. linked git worktree toplevel when it differs from CLAUDE_PROJECT_DIR
#   2. CLAUDE_PROJECT_DIR (Claude session root)
#   3. git rev-parse --show-toplevel (nearest enclosing repo)
#   4. Non-zero return.
#
# CLAUDE_PROJECT_DIR is normally the authoritative session root. Hooks and
# helper scripts are often executed from the plugin checkout while targeting a
# different project, so blindly preferring the plugin repo's git toplevel makes
# active loop state and project config disappear.
#
# The exception is a linked git worktree: explore-idea workers can inherit the
# coordinator's CLAUDE_PROJECT_DIR while running inside their own worktree. In
# that case the current checkout is the safer root.
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
    local env_root="${CLAUDE_PROJECT_DIR:-}"
    local git_root=""
    local root=""

    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$git_root" ]]; then
        git_root="$(canonicalize_path "$git_root")"
    fi
    if [[ -n "$env_root" ]]; then
        env_root="$(canonicalize_path "$env_root")"
    fi

    if [[ -n "$git_root" && -n "$env_root" && "$git_root" != "$env_root" && -f "$git_root/.git" ]]; then
        root="$git_root"
    elif [[ -n "$env_root" ]]; then
        root="$env_root"
    else
        root="$git_root"
    fi
    if [[ -z "$root" ]]; then
        return 1
    fi

    printf '%s\n' "$root"
}

# canonicalize_path_prefix
#
# Resolves symlinks ONLY in the parent directory and reattaches the
# original basename verbatim. This is the right helper for comparing
# user-supplied filenames against an expected path inside a known
# directory: a symlink at /tmp/alias pointing at /real/loop/state.md
# MUST NOT canonicalize to /real/loop/state.md for comparison purposes,
# because `mv` operates on the link path itself. Resolving only the
# parent still lets a symlinked project prefix (e.g. /var vs /private/var
# on macOS) match a canonical expected path.
#
# If realpath on the parent fails, falls back to returning the input
# path unchanged (prefix cannot be canonicalized -> caller's comparison
# will correctly fail against a canonical expected path).
#
# Empty input prints nothing and returns 0.
#
canonicalize_path_prefix() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 0
    fi

    local parent base parent_real
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")

    if parent_real=$(realpath "$parent" 2>/dev/null) && [[ -n "$parent_real" ]]; then
        printf '%s/%s\n' "${parent_real%/}" "$base"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        parent_real=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$parent" 2>/dev/null || true)
        if [[ -n "$parent_real" ]]; then
            printf '%s/%s\n' "${parent_real%/}" "$base"
            return 0
        fi
    fi

    printf '%s\n' "$path"
}

# canonicalize_path
#
# Prints the realpath of the input path. If the path itself does not
# exist yet (common for write validation before the file is created),
# canonicalizes the parent directory and reattaches the basename.
# If realpath is unavailable and python3 is missing, prints the input
# path verbatim.
#
# SECURITY NOTE: This helper dereferences symlinks at the leaf when
# the leaf exists. Do NOT use it to authorize a user-supplied path
# against an expected filename -- use canonicalize_path_prefix instead,
# which only resolves the parent.
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
